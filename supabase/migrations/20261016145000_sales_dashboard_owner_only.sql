-- Restrict sales analytics RPC to the owner even when an employee manually calls the endpoint.
-- Keep the existing, already-reviewed aggregation query intact; only harden its access gate.
do $migration$
declare
  v_definition text;
  v_old text := $old$
  if not coalesce(public.is_active_staff(), false) then
    raise exception 'Acesso restrito à equipe ativa.' using errcode = '42501';
  end if;
$old$;
  v_new text := $new$
  if not coalesce(public.is_active_staff(), false)
     or coalesce(public.current_app_role(), '') <> 'owner' then
    raise exception 'Acesso restrito à proprietária.' using errcode = '42501';
  end if;
$new$;
begin
  select pg_get_functiondef('public.get_sales_dashboard(date,date)'::regprocedure)
  into v_definition;

  if position(v_old in v_definition) = 0 then
    raise exception 'O bloco de autorização esperado não foi encontrado; a migration foi cancelada.';
  end if;

  v_definition := replace(v_definition, v_old, v_new);
  execute v_definition;
end;
$migration$;
