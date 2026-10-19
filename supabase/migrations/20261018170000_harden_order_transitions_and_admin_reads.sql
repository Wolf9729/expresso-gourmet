-- Tighten direct table mutations and enforce valid order-state transitions in the database.
-- The UI uses explicit RPCs; the database remains the authority for the order lifecycle.

revoke update (status) on table public.orders from authenticated;

grant select on table public.products to authenticated;
revoke insert, update, delete on table public.products from authenticated;

grant select on table public.business_settings to authenticated;
drop policy if exists settings_staff_read on public.business_settings;
drop policy if exists settings_owner_read on public.business_settings;
create policy settings_owner_read
on public.business_settings
for select
to authenticated
using (public.is_active_staff() and public.current_app_role() = 'owner' and id = true);

grant select on table public.product_costs to authenticated;
revoke insert, update, delete on table public.product_costs from authenticated;

grant select on table public.profiles to authenticated;
revoke insert, update, delete on table public.profiles from authenticated;

create or replace function public.advance_order_status(
  p_order_id uuid,
  p_next_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_order public.orders%rowtype;
  v_allowed boolean := false;
begin
  if not coalesce(public.is_active_staff(), false) then
    raise exception 'Acesso restrito à equipe ativa.' using errcode = '42501';
  end if;

  if p_order_id is null or p_next_status not in ('confirmed', 'preparing', 'ready', 'completed', 'cancelled') then
    raise exception 'Informe um pedido e um próximo estado válido.' using errcode = '22023';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Pedido não encontrado.' using errcode = 'P0002';
  end if;

  v_allowed :=
    (v_order.status = 'new' and p_next_status in ('confirmed', 'cancelled'))
    or (v_order.status = 'confirmed' and p_next_status in ('preparing', 'cancelled'))
    or (v_order.status = 'preparing' and p_next_status = 'ready')
    or (v_order.status = 'ready' and p_next_status = 'completed');

  if not v_allowed then
    raise exception 'Transição inválida: % → %.', v_order.status, p_next_status using errcode = '22023';
  end if;

  update public.orders
  set status = p_next_status,
      completed_at = case when p_next_status = 'completed' then now() else completed_at end,
      cancelled_at = case when p_next_status = 'cancelled' then now() else cancelled_at end,
      updated_at = now()
  where id = p_order_id;

  return jsonb_build_object(
    'order_id', p_order_id,
    'previous_status', v_order.status,
    'status', p_next_status,
    'order_number', v_order.order_number
  );
end;
$function$;

revoke all on function public.advance_order_status(uuid, text) from public, anon;
grant execute on function public.advance_order_status(uuid, text) to authenticated;
