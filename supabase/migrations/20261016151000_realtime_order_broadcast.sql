-- Private Broadcast channel for active staff. This avoids sending customer/order rows to public subscribers.
grant usage on schema realtime to authenticated;
grant select on table realtime.messages to authenticated;
alter table realtime.messages enable row level security;

drop policy if exists expresso_active_staff_orders_broadcast_select on realtime.messages;
create policy expresso_active_staff_orders_broadcast_select
on realtime.messages
for select
to authenticated
using (
  topic = 'orders'
  and coalesce(public.is_active_staff(), false)
);

create or replace function public.broadcast_order_changes()
returns trigger
language plpgsql
security definer
set search_path = public, realtime, pg_temp
as $function$
begin
  perform realtime.broadcast_changes(
    'orders',
    tg_op,
    tg_op,
    tg_table_name,
    tg_table_schema,
    new,
    old,
    'private'
  );
  return null;
end;
$function$;

revoke all on function public.broadcast_order_changes() from public, anon, authenticated;

drop trigger if exists orders_private_broadcast_changes on public.orders;
create trigger orders_private_broadcast_changes
after insert or update or delete on public.orders
for each row execute function public.broadcast_order_changes();
