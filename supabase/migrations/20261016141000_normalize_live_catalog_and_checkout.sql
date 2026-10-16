-- Expresso Gourmet: move the menu to normalized products and prepare a real pickup checkout.
-- Additive migration: legacy JSONB state is intentionally kept as a recovery/source archive.

alter table public.products
  add column if not exists legacy_id text;

create unique index if not exists products_legacy_id_uidx
  on public.products (legacy_id)
  where legacy_id is not null;

create index if not exists orders_source_created_at_idx
  on public.orders (source, created_at desc);

create table if not exists public.checkout_rate_limits (
  key_hash text primary key check (key_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null,
  request_count integer not null default 1 check (request_count >= 1),
  updated_at timestamptz not null default now()
);

create index if not exists checkout_rate_limits_updated_at_idx
  on public.checkout_rate_limits (updated_at);

alter table public.checkout_rate_limits enable row level security;
revoke all on table public.checkout_rate_limits from public, anon, authenticated;
grant all on table public.checkout_rate_limits to service_role;

create or replace function public.consume_checkout_rate_limit(p_key_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_count integer;
  v_now timestamptz := clock_timestamp();
begin
  if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Chave de limitação inválida.' using errcode = '22023';
  end if;

  insert into public.checkout_rate_limits as current_limit
    (key_hash, window_started_at, request_count, updated_at)
  values (p_key_hash, v_now, 1, v_now)
  on conflict (key_hash) do update
    set request_count = case
          when current_limit.window_started_at <= v_now - interval '10 minutes' then 1
          else current_limit.request_count + 1
        end,
        window_started_at = case
          when current_limit.window_started_at <= v_now - interval '10 minutes' then v_now
          else current_limit.window_started_at
        end,
        updated_at = v_now
  returning request_count into v_count;

  if mod(extract(epoch from v_now)::bigint, 100) = 0 then
    delete from public.checkout_rate_limits
    where updated_at < v_now - interval '1 day';
  end if;

  return v_count <= 6;
end;
$function$;

revoke all on function public.consume_checkout_rate_limit(text) from public, anon, authenticated;
grant execute on function public.consume_checkout_rate_limit(text) to service_role;

-- Import the 63 current legacy products once. Existing normalized edits are never overwritten on rerun.
with legacy_products as (
  select
    p as payload,
    ordinality::integer as sort_order,
    case
      when p->>'category' = 'Almoços' then 'Almoço'
      when p->>'category' = 'Jantas' then 'Jantar'
      when p->>'category' = 'Sobremesas' then 'Doces'
      else coalesce(nullif(trim(p->>'category'), ''), 'Lanches')
    end as category_name
  from public.expresso_owner_private_state s
  cross join lateral jsonb_array_elements(coalesce(s.payload->'products', '[]'::jsonb))
    with ordinality as src(p, ordinality)
  where s.id = true
), category_map as (
  select
    lp.*,
    c.id as category_id
  from legacy_products lp
  join public.categories c on lower(c.name) = lower(lp.category_name)
)
insert into public.products (
  legacy_id, name, description, category_id, image_url,
  price, promo_price, active, available, featured, sort_order, prep_minutes
)
select
  nullif(trim(cm.payload->>'id'), ''),
  trim(cm.payload->>'name'),
  nullif(cm.payload->>'description', ''),
  cm.category_id,
  nullif(cm.payload->>'image', ''),
  (cm.payload->>'price')::numeric,
  case
    when nullif(cm.payload->>'promoPrice', '') ~ '^\d+(\.\d+)?$'
      and (cm.payload->>'promoPrice')::numeric > 0
      and (cm.payload->>'promoPrice')::numeric < (cm.payload->>'price')::numeric
    then (cm.payload->>'promoPrice')::numeric
    else null
  end,
  case when jsonb_typeof(cm.payload->'active') = 'boolean'
    then (cm.payload->>'active')::boolean else true end,
  case when jsonb_typeof(cm.payload->'available') = 'boolean'
    then (cm.payload->>'available')::boolean else true end,
  case when jsonb_typeof(cm.payload->'featured') = 'boolean'
    then (cm.payload->>'featured')::boolean else false end,
  cm.sort_order,
  nullif(cm.payload->>'prepMinutes', '')::integer
from category_map cm
where nullif(trim(cm.payload->>'id'), '') is not null
  and nullif(trim(cm.payload->>'name'), '') is not null
  and coalesce(cm.payload->>'price', '') ~ '^\d+(\.\d+)?$'
on conflict (legacy_id) where legacy_id is not null do nothing;

-- Import costs into the owner-only cost table. Do not overwrite a cost edited after this migration.
insert into public.product_costs (product_id, unit_cost, updated_at)
select p.id, (lp.payload->>'cost')::numeric, now()
from (
  select item as payload
  from public.expresso_owner_private_state s
  cross join lateral jsonb_array_elements(coalesce(s.payload->'products', '[]'::jsonb)) item
  where s.id = true
) lp
join public.products p on p.legacy_id = nullif(trim(lp.payload->>'id'), '')
where coalesce(lp.payload->>'cost', '') ~ '^\d+(\.\d+)?$'
on conflict (product_id) do nothing;

-- Reconcile legacy orders to the relational ledger without treating a selected payment method as proof of payment.
do $migration$
declare
  v_order jsonb;
  v_item jsonb;
  v_source text;
  v_external_id text;
  v_order_id uuid;
  v_item_id uuid;
  v_status text;
  v_payment_status text;
  v_payment_method text;
  v_created_at timestamptz;
  v_amount numeric(12,2);
  v_quantity integer;
  v_unit_price numeric(12,2);
  v_cost numeric(12,2);
  v_item_index integer;
begin
  for v_order in
    select order_payload
    from public.expresso_owner_private_state s
    cross join lateral jsonb_array_elements(coalesce(s.payload->'orders', '[]'::jsonb)) as src(order_payload)
    where s.id = true
      and coalesce(lower(s.payload->'orders'->0->>'demo'), 'false') <> 'true'
  loop
    v_external_id := 'legacy:' || coalesce(nullif(trim(v_order->>'id'), ''), md5(v_order::text));
    v_source := case
      when lower(coalesce(v_order->>'channel','')) like '%whatsapp%' then 'whatsapp'
      else 'manual'
    end;
    v_created_at := coalesce(nullif(v_order->>'createdAt','')::timestamptz, now());

    v_status := case
      when lower(coalesce(v_order->>'status','')) in ('finalizado','finalizada','completed','concluido','concluida') then 'completed'
      when lower(coalesce(v_order->>'status','')) in ('cancelado','cancelada','cancelled','canceled') then 'cancelled'
      when lower(coalesce(v_order->>'status','')) in ('pronto','ready','pronto para retirar') then 'ready'
      when lower(coalesce(v_order->>'status','')) in ('em preparo','em preparacao','preparing') then 'preparing'
      when lower(coalesce(v_order->>'status','')) in ('confirmado','confirmed') then 'confirmed'
      else 'new'
    end;

    v_payment_status := case
      when lower(coalesce(v_order->>'paymentStatus','')) in ('paid','pago','paga','recebido','recebida') then 'paid'
      when lower(coalesce(v_order->>'paymentStatus','')) in ('refunded','estornado','estornada') then 'refunded'
      when lower(coalesce(v_order->>'paymentStatus','')) in ('failed','falhou','falha') then 'failed'
      else 'pending'
    end;

    v_payment_method := case
      when lower(coalesce(v_order->>'payment','')) like '%pix%' then 'pix'
      when lower(coalesce(v_order->>'payment','')) like '%dinheiro%' then 'cash'
      when lower(coalesce(v_order->>'payment','')) like '%débito%' or lower(coalesce(v_order->>'payment','')) like '%debito%' then 'debit'
      when lower(coalesce(v_order->>'payment','')) like '%crédito%' or lower(coalesce(v_order->>'payment','')) like '%credito%' then 'credit'
      when nullif(trim(v_order->>'payment'),'') is not null then 'other'
      else null
    end;

    select id into v_order_id
    from public.orders
    where source = v_source and external_id = v_external_id
    limit 1;

    if v_order_id is null then
      insert into public.orders (
        customer_name, customer_phone, source, external_id, status,
        payment_method, payment_status, subtotal, discount_amount,
        campaign_discount, fees, total, notes, created_at, updated_at, completed_at, cancelled_at
      )
      values (
        coalesce(nullif(trim(v_order->>'customer'), ''), 'Cliente legado'),
        nullif(trim(v_order->>'phone'), ''),
        v_source,
        v_external_id,
        v_status,
        v_payment_method,
        v_payment_status,
        coalesce(nullif(v_order->>'subtotal','')::numeric, nullif(v_order->>'total','')::numeric, 0),
        coalesce(nullif(v_order->>'discount','')::numeric, 0),
        0, 0,
        coalesce(nullif(v_order->>'total','')::numeric, 0),
        coalesce(nullif(v_order->>'note',''), 'Importado do histórico anterior'),
        v_created_at, now(),
        case when v_status = 'completed' then v_created_at else null end,
        case when v_status = 'cancelled' then v_created_at else null end
      )
      returning id into v_order_id;
    end if;

    if not exists (select 1 from public.order_items oi where oi.order_id = v_order_id) then
      v_item_index := 0;
      for v_item in
        select item
        from jsonb_array_elements(coalesce(v_order->'items', '[]'::jsonb)) as item
      loop
        v_quantity := coalesce(nullif(coalesce(v_item->>'qty', v_item->>'quantity'), '')::integer, 0);
        v_unit_price := coalesce(nullif(coalesce(v_item->>'price', v_item->>'unit_price'), '')::numeric, 0);
        v_cost := nullif(v_item->>'cost', '')::numeric;

        if v_quantity > 0 and v_unit_price >= 0 then
          -- product_id is left null for historical rows so the product trigger cannot rewrite historic prices.
          insert into public.order_items (
            order_id, product_id, product_name, quantity, unit_price, discount_amount, notes
          )
          values (
            v_order_id,
            null,
            coalesce(nullif(trim(v_item->>'name'), ''), 'Produto legado'),
            v_quantity,
            v_unit_price,
            0,
            nullif(trim(v_item->>'notes'), '')
          )
          returning id into v_item_id;

          if v_cost is not null and v_cost >= 0 then
            insert into public.order_item_costs (order_item_id, unit_cost, captured_at)
            values (v_item_id, v_cost, v_created_at)
            on conflict (order_item_id) do nothing;
          end if;
          v_item_index := v_item_index + 1;
        end if;
      end loop;
    end if;

    if v_payment_method is not null and not exists (
      select 1 from public.payments pay where pay.order_id = v_order_id
    ) then
      select coalesce(sum(oi.line_total), 0) into v_amount
      from public.order_items oi where oi.order_id = v_order_id;
      insert into public.payments (order_id, method, amount, status, reference, created_at)
      values (v_order_id, v_payment_method, v_amount, v_payment_status, 'Importado do histórico anterior', v_created_at);
    end if;
  end loop;
end;
$migration$;

-- Keep the identity sequence ahead of all imported/current order numbers.
do $sequence$
declare
  v_seq text;
  v_max bigint;
begin
  v_seq := pg_get_serial_sequence('public.orders', 'order_number');
  select max(order_number) into v_max from public.orders;
  if v_seq is not null then
    if v_max is null then
      perform setval(v_seq::regclass, 1, false);
    else
      perform setval(v_seq::regclass, v_max, true);
    end if;
  end if;
end;
$sequence$;

-- Build the public card from normalized product rows while preserving store settings and campaign display.
create or replace function public.refresh_expresso_public_catalog_from_products()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_products jsonb;
  v_campaigns jsonb;
  v_settings jsonb;
begin
  select coalesce(payload->'campaigns', '[]'::jsonb),
         coalesce(payload->'settings', '{}'::jsonb)
  into v_campaigns, v_settings
  from public.expresso_public_catalog
  where id = true;

  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'id', coalesce(p.legacy_id, p.id::text),
    'name', p.name,
    'category', c.name,
    'description', p.description,
    'price', p.price,
    'promoPrice', p.promo_price,
    'image', coalesce(p.image_url, ''),
    'active', p.active,
    'available', p.available,
    'featured', p.featured
  )) order by p.featured desc, p.sort_order, p.name), '[]'::jsonb)
  into v_products
  from public.products p
  left join public.categories c on c.id = p.category_id
  where p.active = true;

  update public.expresso_public_catalog
  set payload = jsonb_build_object(
    'products', v_products,
    'campaigns', coalesce(v_campaigns, '[]'::jsonb),
    'settings', coalesce(v_settings, '{}'::jsonb)
  ),
  updated_at = now()
  where id = true;
end;
$function$;

create or replace function public.sync_expresso_public_catalog_after_product_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  perform public.refresh_expresso_public_catalog_from_products();
  if tg_op = 'DELETE' then return old; else return new; end if;
end;
$function$;

revoke all on function public.refresh_expresso_public_catalog_from_products() from public, anon, authenticated;
revoke all on function public.sync_expresso_public_catalog_after_product_change() from public, anon, authenticated;

drop trigger if exists products_sync_expresso_public_catalog on public.products;
create trigger products_sync_expresso_public_catalog
after insert or update or delete on public.products
for each statement execute function public.sync_expresso_public_catalog_after_product_change();

drop trigger if exists categories_sync_expresso_public_catalog on public.categories;
create trigger categories_sync_expresso_public_catalog
after update on public.categories
for each statement execute function public.sync_expresso_public_catalog_after_product_change();

select public.refresh_expresso_public_catalog_from_products();

-- The unguessable external UUID is the customer-facing capability token; this RPC returns no PII.
revoke all on function public.get_public_order_confirmation(text) from public, anon, authenticated;
grant execute on function public.get_public_order_confirmation(text) to anon, authenticated;

-- Realtime queue and reporting access are tied to authenticated active staff; the public can only create
-- orders through the rate-limited Edge Function, which uses the service role server-side.
