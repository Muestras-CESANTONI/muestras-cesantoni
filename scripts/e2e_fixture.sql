-- TEST ENVIRONMENT ONLY: publishes a few migrated SKUs so the public pages can be exercised.
-- In production CESANTONI publishes each SKU after validating names, colors, finish, size and photo.
update public.sample_skus set public_enabled = true, catalog_verified = true
 where code in ('HOUSTON2-001','HOUSTON2-002','HOUSTON2-003','HOUSTON2-138','HOUSTON2-139','HOUSTON2-069',
                'HOUSTON2-063','HOUSTON2-087','HOUSTON2-142','HOUSTON2-099','HOUSTON2-032');
update public.settings set value = 'false' where key = 'require_validated_image';
update public.settings set value = '1000' where key in ('rate_limit_per_hour', 'rate_limit_per_email_day');
