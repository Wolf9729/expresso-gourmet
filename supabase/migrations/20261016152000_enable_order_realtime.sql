-- Enable authenticated active staff to receive row-level changes for the order queue.
-- RLS on public.orders remains responsible for which records an authenticated staff member can see.
do $migration$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
end;
$migration$;
