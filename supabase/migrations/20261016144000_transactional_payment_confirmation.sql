-- Transactional payment confirmation for the real pickup flow.
create unique index if not exists payments_one_row_per_order_uidx
  on public.payments (order_id);

create or replace function public.set_order_payment_status(
  p_order_id uuid,
  p_status text,
  p_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_order public.orders%rowtype;
  v_method text;
  v_reference text;
begin
  if not coalesce(public.is_active_staff(), false)
     or coalesce(public.current_app_role(), '') not in ('owner','employee') then
    raise exception 'Acesso restrito à equipe ativa.' using errcode = '42501';
  end if;
  if p_order_id is null or p_status not in ('pending','paid','refunded','failed') then
    raise exception 'Informe um pedido e um estado de pagamento válido.' using errcode = '22023';
  end if;
  if p_reference is not null and length(trim(p_reference)) > 160 then
    raise exception 'A referência do pagamento é muito longa.' using errcode = '22023';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Pedido não encontrado.' using errcode = 'P0002';
  end if;
  if v_order.status = 'cancelled' and p_status = 'paid' then
    raise exception 'Não é possível confirmar pagamento de um pedido cancelado.' using errcode = '22023';
  end if;

  v_method := coalesce(v_order.payment_method, 'other');
  v_reference := nullif(trim(p_reference), '');

  update public.orders
  set payment_status = p_status,
      updated_at = now()
  where id = p_order_id;

  insert into public.payments (order_id, method, amount, status, reference, recorded_by, created_at)
  values (p_order_id, v_method, v_order.total, p_status, v_reference, auth.uid(), now())
  on conflict (order_id) do update
    set method = excluded.method,
        amount = excluded.amount,
        status = excluded.status,
        reference = excluded.reference,
        recorded_by = excluded.recorded_by,
        created_at = now();

  return jsonb_build_object(
    'order_id', p_order_id,
    'payment_status', p_status,
    'order_status', v_order.status,
    'total', v_order.total
  );
end;
$function$;

revoke all on function public.set_order_payment_status(uuid,text,text) from public, anon;
grant execute on function public.set_order_payment_status(uuid,text,text) to authenticated;
