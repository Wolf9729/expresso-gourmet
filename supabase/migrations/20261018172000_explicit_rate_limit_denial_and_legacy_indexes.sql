-- Make the intended default-deny posture explicit for browser roles.
-- service_role remains the only role granted table access and bypasses RLS by design.
drop policy if exists checkout_rate_limits_deny_clients on public.checkout_rate_limits;
create policy checkout_rate_limits_deny_clients
on public.checkout_rate_limits
for all
to anon, authenticated
using (false)
with check (false);

-- Cover the legacy state-table foreign keys flagged by the database advisor.
create index if not exists expresso_app_state_updated_by_idx
  on public.expresso_app_state (updated_by);

create index if not exists expresso_owner_private_state_updated_by_idx
  on public.expresso_owner_private_state (updated_by);
