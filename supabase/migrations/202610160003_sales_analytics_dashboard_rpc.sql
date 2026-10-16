-- Read-only operational sales analytics, scoped to active staff and existing RLS.
create or replace function public.get_sales_dashboard(
  p_from date default ((timezone('America/Fortaleza', now()))::date - 29),
  p_to date default ((timezone('America/Fortaleza', now()))::date)
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare v_from timestamptz; v_to timestamptz; v_days integer; v_result jsonb;
begin
  if not coalesce(public.is_active_staff(), false) then
    raise exception 'Acesso restrito à equipe ativa.' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Informe um período válido.' using errcode = '22023';
  end if;
  v_days := p_to - p_from + 1;
  if v_days > 366 then
    raise exception 'O período máximo é de 366 dias.' using errcode = '22023';
  end if;
  v_from := p_from::timestamp at time zone 'America/Fortaleza';
  v_to := (p_to + 1)::timestamp at time zone 'America/Fortaleza';
  with
  base_orders as materialized (select o.* from public.orders o where o.created_at >= v_from and o.created_at < v_to),
  completed_orders as materialized (select * from base_orders where status = 'completed'),
  daily_range as (select g.day::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') as g(day)),
  daily_orders as (
    select (o.created_at at time zone 'America/Fortaleza')::date as day, count(*)::integer as order_count,
      count(*) filter (where o.payment_status = 'paid')::integer as paid_orders,
      coalesce(sum(o.total) filter (where o.payment_status = 'paid'), 0)::numeric(14,2) as paid_revenue
    from completed_orders o group by 1
  ),
  daily_items as (
    select (o.created_at at time zone 'America/Fortaleza')::date as day, coalesce(sum(i.quantity),0)::integer as units_sold
    from completed_orders o join public.order_items i on i.order_id=o.id group by 1
  ),
  weekday_orders as (
    select extract(isodow from o.created_at at time zone 'America/Fortaleza')::integer as weekday,
      count(*)::integer as order_count, count(*) filter (where o.payment_status='paid')::integer as paid_orders,
      coalesce(sum(o.total) filter (where o.payment_status='paid'),0)::numeric(14,2) as paid_revenue
    from completed_orders o group by 1
  ),
  weekday_items as (
    select extract(isodow from o.created_at at time zone 'America/Fortaleza')::integer as weekday,
      coalesce(sum(i.quantity),0)::integer as units_sold
    from completed_orders o join public.order_items i on i.order_id=o.id group by 1
  ),
  top_products as (
    select i.product_name as name, coalesce(sum(i.quantity),0)::integer as units_sold,
      coalesce(sum(i.line_total),0)::numeric(14,2) as gross_sales
    from completed_orders o join public.order_items i on i.order_id=o.id
    group by i.product_name order by sum(i.quantity) desc, sum(i.line_total) desc, i.product_name limit 10
  ),
  hourly_orders as (
    select extract(hour from o.created_at at time zone 'America/Fortaleza')::integer as hour,
      count(*)::integer as order_count, count(*) filter (where o.payment_status='paid')::integer as paid_orders,
      coalesce(sum(o.total) filter (where o.payment_status='paid'),0)::numeric(14,2) as paid_revenue
    from completed_orders o group by 1
  ),
  hourly_items as (
    select extract(hour from o.created_at at time zone 'America/Fortaleza')::integer as hour,
      coalesce(sum(i.quantity),0)::integer as units_sold
    from completed_orders o join public.order_items i on i.order_id=o.id group by 1
  ),
  previous_period as (
    select count(*) filter (where status='completed')::integer as completed_orders,
      count(*) filter (where status='completed' and payment_status='paid')::integer as paid_orders,
      coalesce(sum(total) filter (where status='completed' and payment_status='paid'),0)::numeric(14,2) as paid_revenue
    from public.orders where created_at >= (v_from - (v_to - v_from)) and created_at < v_from
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',p_from,'to',p_to,'days',v_days),
    'summary',(select jsonb_build_object(
      'orders',count(*)::integer,
      'open_orders',count(*) filter (where status in ('new','confirmed','preparing','ready'))::integer,
      'completed_orders',count(*) filter (where status='completed')::integer,
      'cancelled_orders',count(*) filter (where status='cancelled')::integer,
      'paid_orders',count(*) filter (where status='completed' and payment_status='paid')::integer,
      'paid_revenue',coalesce(sum(total) filter (where status='completed' and payment_status='paid'),0)::numeric(14,2),
      'average_paid_ticket',coalesce(avg(total) filter (where status='completed' and payment_status='paid'),0)::numeric(14,2),
      'units_sold',(select coalesce(sum(i.quantity),0)::integer from completed_orders o join public.order_items i on i.order_id=o.id)
    ) from base_orders),
    'daily',(select coalesce(jsonb_agg(jsonb_build_object(
      'date',dr.day,
      'day',case extract(isodow from dr.day)::integer when 1 then 'Segunda-feira' when 2 then 'Terça-feira' when 3 then 'Quarta-feira' when 4 then 'Quinta-feira' when 5 then 'Sexta-feira' when 6 then 'Sábado' else 'Domingo' end,
      'orders',coalesce(dor.order_count,0),'paid_orders',coalesce(dor.paid_orders,0),'paid_revenue',coalesce(dor.paid_revenue,0),'units_sold',coalesce(di.units_sold,0)
    ) order by dr.day),'[]'::jsonb) from daily_range dr left join daily_orders dor on dor.day=dr.day left join daily_items di on di.day=dr.day),
    'weekdays',(select coalesce(jsonb_agg(jsonb_build_object(
      'weekday',w.weekday,
      'day',case w.weekday when 1 then 'Segunda-feira' when 2 then 'Terça-feira' when 3 then 'Quarta-feira' when 4 then 'Quinta-feira' when 5 then 'Sexta-feira' when 6 then 'Sábado' else 'Domingo' end,
      'orders',coalesce(wo.order_count,0),'paid_orders',coalesce(wo.paid_orders,0),'paid_revenue',coalesce(wo.paid_revenue,0),'units_sold',coalesce(wi.units_sold,0)
    ) order by w.weekday),'[]'::jsonb) from generate_series(1,7) as w(weekday) left join weekday_orders wo on wo.weekday=w.weekday left join weekday_items wi on wi.weekday=w.weekday),
    'top_products',(select coalesce(jsonb_agg(jsonb_build_object('name',tp.name,'units_sold',tp.units_sold,'gross_sales',tp.gross_sales) order by tp.units_sold desc,tp.gross_sales desc,tp.name),'[]'::jsonb) from top_products tp),
    'hours',(select coalesce(jsonb_agg(jsonb_build_object('hour',h.hour,'orders',coalesce(ho.order_count,0),'paid_orders',coalesce(ho.paid_orders,0),'paid_revenue',coalesce(ho.paid_revenue,0),'units_sold',coalesce(hi.units_sold,0)) order by h.hour),'[]'::jsonb) from generate_series(0,23) as h(hour) left join hourly_orders ho on ho.hour=h.hour left join hourly_items hi on hi.hour=h.hour),
    'comparison',(select jsonb_build_object('previous_completed_orders',completed_orders,'previous_paid_orders',paid_orders,'previous_paid_revenue',paid_revenue) from previous_period),
    'methodology',jsonb_build_object('units_and_products','Pedidos finalizados; unidades e valores por item registrados nos pedidos.','paid_revenue','Soma dos pedidos finalizados com pagamento marcado como pago.','timezone','America/Fortaleza')
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.get_sales_dashboard(date,date) from public, anon;
grant execute on function public.get_sales_dashboard(date,date) to authenticated;
