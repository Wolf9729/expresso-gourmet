-- Admin catalog editor only reads categories for its dropdown today.
-- Grant the required read path and remove direct mutations until a validated category RPC exists.
grant select on table public.categories to authenticated;
revoke insert, update, delete on table public.categories from authenticated;
