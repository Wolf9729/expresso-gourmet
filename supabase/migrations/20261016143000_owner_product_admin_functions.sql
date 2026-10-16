-- Owner-only catalog/settings administration. Every write stays in a transaction and triggers catalog refresh.

alter table public.business_settings
  add column if not exists accept_orders boolean not null default true;

update public.business_settings bs
set accept_orders = coalesce(
  (select nullif(s.payload->'settings'->>'acceptOrders','')::boolean
   from public.expresso_owner_private_state s where s.id = true),
  bs.accept_orders
)
where bs.id = true;

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
  v_hours jsonb;
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
  where p.active = true and coalesce(c.active, true) = true;

  select opening_hours into v_hours
  from public.business_settings where id = true;

  select v_settings || jsonb_build_object(
    'name', store_name,
    'campus', location,
    'whatsapp', whatsapp_number,
    'instagramUrl', instagram_url,
    'accent', primary_color,
    'acceptOrders', accept_orders
  )
  into v_settings
  from public.business_settings
  where id = true;

  if v_hours is not null and v_hours <> '{}'::jsonb then
    v_settings := jsonb_set(v_settings, '{schedule}', v_hours, true);
  end if;

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

create or replace function public.admin_save_product(
  p_product_id uuid,
  p_legacy_id text,
  p_name text,
  p_description text,
  p_category_id uuid,
  p_image_url text,
  p_price numeric,
  p_promo_price numeric,
  p_unit_cost numeric,
  p_active boolean,
  p_available boolean,
  p_featured boolean,
  p_sort_order integer,
  p_prep_minutes integer
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_id uuid;
  v_legacy_id text;
begin
  if not coalesce(public.is_active_staff(), false)
     or coalesce(public.current_app_role(), '') <> 'owner' then
    raise exception 'Somente a proprietária pode editar produtos e custos.' using errcode = '42501';
  end if;

  if nullif(trim(p_name), '') is null or length(trim(p_name)) > 120 then
    raise exception 'Informe um nome de produto de até 120 caracteres.' using errcode = '22023';
  end if;
  if p_description is not null and length(p_description) > 1000 then
    raise exception 'A descrição pode ter até 1.000 caracteres.' using errcode = '22023';
  end if;
  if p_price is null or p_price < 0 or p_price > 100000 then
    raise exception 'Informe um preço válido.' using errcode = '22023';
  end if;
  if p_promo_price is not null and (p_promo_price <= 0 or p_promo_price >= p_price) then
    raise exception 'O preço promocional deve ser menor que o preço regular.' using errcode = '22023';
  end if;
  if p_unit_cost is not null and (p_unit_cost < 0 or p_unit_cost > 100000) then
    raise exception 'Informe um custo válido.' using errcode = '22023';
  end if;
  if p_category_id is null or not exists (
    select 1 from public.categories c where c.id = p_category_id and c.active = true
  ) then
    raise exception 'Selecione uma categoria ativa.' using errcode = '22023';
  end if;
  if p_image_url is not null and length(p_image_url) > 2048 then
    raise exception 'O endereço da imagem é muito longo.' using errcode = '22023';
  end if;
  if p_image_url is not null and trim(p_image_url) <> ''
     and p_image_url not like 'https://%' and p_image_url not like 'img:%' then
    raise exception 'Use uma imagem HTTPS ou uma referência de imagem existente.' using errcode = '22023';
  end if;

  if p_product_id is null then
    insert into public.products (
      legacy_id, name, description, category_id, image_url, price, promo_price,
      active, available, featured, sort_order, prep_minutes
    ) values (
      nullif(trim(p_legacy_id), ''), trim(p_name), nullif(trim(p_description), ''),
      p_category_id, nullif(trim(p_image_url), ''), p_price, p_promo_price,
      coalesce(p_active, true), coalesce(p_available, true), coalesce(p_featured, false),
      coalesce(p_sort_order, 0), p_prep_minutes
    )
    returning id into v_id;
  else
    select legacy_id into v_legacy_id
    from public.products where id = p_product_id for update;

    if not found then
      raise exception 'Produto não encontrado.' using errcode = 'P0002';
    end if;

    update public.products
    set legacy_id = coalesce(nullif(trim(p_legacy_id), ''), v_legacy_id),
        name = trim(p_name),
        description = nullif(trim(p_description), ''),
        category_id = p_category_id,
        image_url = nullif(trim(p_image_url), ''),
        price = p_price,
        promo_price = p_promo_price,
        active = coalesce(p_active, true),
        available = coalesce(p_available, true),
        featured = coalesce(p_featured, false),
        sort_order = coalesce(p_sort_order, 0),
        prep_minutes = p_prep_minutes,
        updated_at = now()
    where id = p_product_id
    returning id into v_id;
  end if;

  if p_unit_cost is not null then
    insert into public.product_costs (product_id, unit_cost, updated_by, updated_at)
    values (v_id, p_unit_cost, auth.uid(), now())
    on conflict (product_id) do update
      set unit_cost = excluded.unit_cost,
          updated_by = excluded.updated_by,
          updated_at = now();
  end if;

  return v_id;
end;
$function$;

revoke all on function public.admin_save_product(uuid,text,text,text,uuid,text,numeric,numeric,numeric,boolean,boolean,boolean,integer,integer) from public, anon;
grant execute on function public.admin_save_product(uuid,text,text,text,uuid,text,numeric,numeric,numeric,boolean,boolean,boolean,integer,integer) to authenticated;

create or replace function public.set_product_availability(p_product_id uuid, p_available boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if not coalesce(public.is_active_staff(), false)
     or coalesce(public.current_app_role(), '') not in ('owner', 'employee') then
    raise exception 'Acesso restrito à equipe ativa.' using errcode = '42501';
  end if;
  if p_product_id is null or p_available is null then
    raise exception 'Informe o produto e a disponibilidade.' using errcode = '22023';
  end if;
  update public.products set available = p_available, updated_at = now()
  where id = p_product_id and active = true;
  if not found then
    raise exception 'Produto não encontrado ou inativo.' using errcode = 'P0002';
  end if;
end;
$function$;

revoke all on function public.set_product_availability(uuid,boolean) from public, anon;
grant execute on function public.set_product_availability(uuid,boolean) to authenticated;

create or replace function public.admin_update_store_settings(
  p_store_name text,
  p_tagline text,
  p_location text,
  p_whatsapp_number text,
  p_instagram_url text,
  p_primary_color text,
  p_accept_orders boolean,
  p_pickup_enabled boolean,
  p_opening_hours jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if not coalesce(public.is_active_staff(), false)
     or coalesce(public.current_app_role(), '') <> 'owner' then
    raise exception 'Somente a proprietária pode alterar as configurações.' using errcode = '42501';
  end if;
  if nullif(trim(p_store_name), '') is null or length(trim(p_store_name)) > 100 then
    raise exception 'Informe o nome da loja.' using errcode = '22023';
  end if;
  if p_tagline is not null and length(p_tagline) > 180 then
    raise exception 'O texto de apresentação é muito longo.' using errcode = '22023';
  end if;
  if p_location is not null and length(p_location) > 180 then
    raise exception 'O local informado é muito longo.' using errcode = '22023';
  end if;
  if p_whatsapp_number is not null
     and length(regexp_replace(p_whatsapp_number, '\D', '', 'g')) not between 10 and 15 then
    raise exception 'Informe um WhatsApp válido com DDD.' using errcode = '22023';
  end if;
  if p_instagram_url is not null and p_instagram_url <> ''
     and p_instagram_url not like 'https://%' then
    raise exception 'A URL do Instagram deve começar com HTTPS.' using errcode = '22023';
  end if;
  if p_primary_color is null or p_primary_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'Selecione uma cor hexadecimal válida.' using errcode = '22023';
  end if;
  if p_opening_hours is not null and jsonb_typeof(p_opening_hours) not in ('object','array') then
    raise exception 'Os horários precisam ser informados em um formato válido.' using errcode = '22023';
  end if;

  update public.business_settings
  set store_name = trim(p_store_name),
      tagline = nullif(trim(p_tagline), ''),
      location = nullif(trim(p_location), ''),
      whatsapp_number = nullif(regexp_replace(coalesce(p_whatsapp_number,''), '\D', '', 'g'), ''),
      instagram_url = nullif(trim(p_instagram_url), ''),
      primary_color = p_primary_color,
      accept_orders = coalesce(p_accept_orders, true),
      pickup_enabled = coalesce(p_pickup_enabled, true),
      delivery_enabled = false,
      opening_hours = coalesce(p_opening_hours, '{}'::jsonb),
      updated_by = auth.uid(),
      updated_at = now()
  where id = true;

  perform public.refresh_expresso_public_catalog_from_products();
end;
$function$;

revoke all on function public.admin_update_store_settings(text,text,text,text,text,text,boolean,boolean,jsonb) from public, anon;
grant execute on function public.admin_update_store_settings(text,text,text,text,text,text,boolean,boolean,jsonb) to authenticated;

create or replace function public.admin_set_employee_active(p_user_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_role text;
begin
  if not coalesce(public.is_active_staff(), false)
     or coalesce(public.current_app_role(), '') <> 'owner' then
    raise exception 'Somente a proprietária pode gerenciar acessos.' using errcode = '42501';
  end if;
  if p_user_id is null or p_active is null then
    raise exception 'Informe o usuário e o estado de acesso.' using errcode = '22023';
  end if;
  if p_user_id = auth.uid() and p_active = false then
    raise exception 'Você não pode desativar sua própria sessão.' using errcode = '42501';
  end if;
  select role into v_role from public.profiles where id = p_user_id for update;
  if not found or v_role <> 'employee' then
    raise exception 'Somente contas de funcionários podem ser alteradas aqui.' using errcode = '42501';
  end if;
  update public.profiles set active = p_active, updated_at = now()
  where id = p_user_id;
end;
$function$;

revoke all on function public.admin_set_employee_active(uuid,boolean) from public, anon;
grant execute on function public.admin_set_employee_active(uuid,boolean) to authenticated;

create or replace function public.sync_expresso_settings_after_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  perform public.refresh_expresso_public_catalog_from_products();
  return new;
end;
$function$;

drop trigger if exists business_settings_sync_expresso_public_catalog on public.business_settings;
create trigger business_settings_sync_expresso_public_catalog
after update on public.business_settings
for each row execute function public.sync_expresso_settings_after_update();

revoke all on function public.sync_expresso_settings_after_update() from public, anon, authenticated;

select public.refresh_expresso_public_catalog_from_products();
