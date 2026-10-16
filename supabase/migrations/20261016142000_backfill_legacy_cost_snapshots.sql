-- Backfill missing cost snapshots for historical items, without changing their recorded sale prices.
with legacy_items as (
  select
    'legacy:' || coalesce(nullif(trim(o->>'id'), ''), md5(o::text)) as external_id,
    nullif(trim(item->>'name'), '') as product_name,
    nullif(item->>'cost', '')::numeric as unit_cost
  from public.expresso_owner_private_state s
  cross join lateral jsonb_array_elements(coalesce(s.payload->'orders','[]'::jsonb)) as orders(o)
  cross join lateral jsonb_array_elements(coalesce(o->'items','[]'::jsonb)) as items(item)
  where s.id = true
    and coalesce(lower(o->>'demo'), 'false') <> 'true'
    and coalesce(item->>'cost','') ~ '^\d+(\.\d+)?$'
)
update public.order_item_costs c
set unit_cost = li.unit_cost,
    captured_at = o.created_at
from public.order_items i
join public.orders o on o.id = i.order_id
join legacy_items li on li.external_id = o.external_id and li.product_name = i.product_name
where c.order_item_id = i.id
  and o.external_id like 'legacy:%'
  and c.unit_cost is null;
