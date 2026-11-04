-- PASO 4 · Publicar en el catálogo todos los productos con existencia (decisión de CESANTONI, 2026-11-04).
-- Pegar en Supabase › SQL Editor › Run. Se puede ejecutar más de una vez.
-- Mientras se cargan las fotos oficiales, el catálogo muestra "Photo coming soon".
begin;
update public.settings
   set value = 'false', updated_at = now()
 where key = 'require_validated_image';

update public.sample_skus k
   set public_enabled = true, catalog_verified = true
 where k.status = 'active'
   and (select coalesce(sum(s.on_hand - s.reserved), 0) from public.stock s where s.sku_id = k.id) > 0;
commit;

-- Resultado: productos publicados y cuántos se ven en el catálogo
select (select count(*) from public.sample_skus where public_enabled) as sku_publicados,
       (select count(*) from public.catalog_items()) as visibles_en_catalogo;
