-- Only the status column may be updated directly by authenticated staff.
-- Totals, item rows and payment records are written through trusted transactional functions.
revoke insert, update, delete on table public.orders from authenticated;
grant update (status) on table public.orders to authenticated;

revoke insert, update, delete on table public.order_items from authenticated;
grant select on table public.order_items to authenticated;

revoke insert, update, delete on table public.payments from authenticated;
grant select on table public.payments to authenticated;
