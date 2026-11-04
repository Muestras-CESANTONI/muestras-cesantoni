-- PASO 5 · Pegar en Supabase › SQL Editor › Run. Se puede ejecutar más de una vez.
-- Catalog shows the available pieces of each sample option (Sample Studio design).
drop function if exists public.catalog_items();
create function public.catalog_items()
returns table (sku_code text, model text, product_name text, category app.product_category, color text, finish text,
               sample_type app.sample_type, sample_size text, max_selectable integer, available integer,
               image_path text, image_kind text)
language sql stable security definer set search_path = public, app as $$
  with avail as (
    select s.sku_id, sum(s.on_hand - s.reserved)::int as available
      from public.stock s
     where coalesce((app.setting('allow_requests_on_unvalidated_stock'))::boolean, true) or s.validation_status = 'validated'
     group by s.sku_id)
  select k.code, p.model, p.display_name_en, p.category, v.color_en, f.name_en, k.sample_type, k.sample_size_en,
         least(k.max_per_request, a.available), a.available, img.storage_path, img.kind
    from public.sample_skus k
    join avail a on a.sku_id = k.id and a.available > 0
    join public.variants v on v.id = k.variant_id and v.status = 'active'
    join public.products p on p.id = v.product_id and p.status = 'active'
    join public.finishes f on f.code = v.finish_code
    left join public.variant_images img on img.variant_id = v.id and img.is_primary and img.validated
   where k.public_enabled and k.catalog_verified and k.status = 'active'
     and (img.id is not null or not coalesce((app.setting('require_validated_image'))::boolean, true))
   order by p.display_name_en, f.name_en, v.color_en nulls first, k.sample_type, k.sample_size_en
$$;
grant execute on function public.catalog_items() to anon, authenticated;
