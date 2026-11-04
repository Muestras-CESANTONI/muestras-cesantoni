# Puesta en marcha · Supabase + GitHub Pages (desde el navegador)

Proyecto Supabase: `wetjwphgdcjcukuwlfwl` · URL `https://wetjwphgdcjcukuwlfwl.supabase.co`
Sitio: `https://muestras-cesantoni.github.io/` (repositorio `Muestras-CESANTONI/muestras-cesantoni.github.io`)

Archivos (en el repositorio, carpeta `supabase/deploy/`, salvo el de datos que se entrega aparte porque contiene datos personales):
`01_estructura.sql`, `02_datos_iniciales.sql`, `functions/submit-request.ts`, `cron_proyecto.sql`.

## Paso 1 · Estructura de la base (una sola vez)
1. Supabase › **SQL Editor** › **New query**: https://supabase.com/dashboard/project/wetjwphgdcjcukuwlfwl/sql/new
2. Abre `01_estructura.sql`, copia **todo**, pégalo y da clic en **Run**. Debe terminar con *Success. No rows returned*.
   Si marca error, no sigas: envía el mensaje completo.

## Paso 2 · Datos iniciales (una sola vez)
1. **New query** otra vez, pega todo `02_datos_iniciales.sql` y **Run**. Es una sola transacción: si algo falla no queda nada a medias.
   (Si el editor dice que el texto es demasiado largo, avísame y lo divido en partes.)
2. Comprobación (nueva consulta):
   ```sql
   select count(*) as sku, sum(on_hand) as piezas from public.stock;   -- esperado: 171 · 7061
   select count(*) as folios from public.requests;                     -- esperado: 12
   select public.folio_sequence_sync();                                -- siguiente folio: 13
   ```

## Paso 3 · Función que recibe las solicitudes
1. **Edge Functions** › **Deploy a new function** › **Via Editor**: https://supabase.com/dashboard/project/wetjwphgdcjcukuwlfwl/functions
2. Nombre exacto: `submit-request`. Borra el código de ejemplo y pega todo `functions/submit-request.ts`. **Deploy**.
3. En la función › **Details**: desactiva **Enforce JWT verification** (el formulario es público; la función valida origen, datos y abuso). Guarda.
4. **Edge Functions › Secrets** (https://supabase.com/dashboard/project/wetjwphgdcjcukuwlfwl/functions/secrets), agrega:
   | Nombre | Valor |
   |---|---|
   | `ALLOWED_ORIGINS` | `https://muestras-cesantoni.github.io` |
   | `PUBLIC_SITE_URL` | `https://muestras-cesantoni.github.io` |
   | `TRACKING_SECRET` | texto aleatorio de 40+ caracteres (de un generador de contraseñas) |
   | `FINGERPRINT_SALT` | otro texto aleatorio distinto de 40+ caracteres |
   No compartas estos valores. `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` ya existen solos.

Las funciones `notify-worker` y `email-webhook` y `cron_proyecto.sql` se instalan cuando exista el proveedor de correo (Resend con dominio verificado). Mientras tanto los avisos quedan **en cola** en la base (tabla `notifications`) y se enviarán en cuanto el procesador esté activo; nada se pierde.

## Paso 4 · Publicar el sitio
1. GitHub › **Settings › Pages** › **Source: GitHub Actions**: https://github.com/Muestras-CESANTONI/muestras-cesantoni.github.io/settings/pages
2. GitHub › **Settings › Secrets and variables › Actions › pestaña Variables › New repository variable**:
   https://github.com/Muestras-CESANTONI/muestras-cesantoni.github.io/settings/variables/actions
   | Nombre | Valor (Supabase › Project Settings › API Keys) |
   |---|---|
   | `SUPABASE_URL` | `https://wetjwphgdcjcukuwlfwl.supabase.co` |
   | `SUPABASE_ANON_KEY` | la llave **anon public** (`eyJ…`) o la **publishable** (`sb_publishable_…`) — **nunca** la `service_role` / `secret` |
3. GitHub › **Actions › Publish site › Run workflow**: https://github.com/Muestras-CESANTONI/muestras-cesantoni.github.io/actions
   En 1–2 minutos queda en `https://muestras-cesantoni.github.io/`.

## Qué verás al publicar
El catálogo abrirá con el aviso *"No samples are available right now"*: **es lo esperado**. Ningún SKU se publica hasta que CESANTONI valide nombre en inglés, color, acabado, tamaño y foto (regla del proyecto). Mientras se construye el panel interno, la publicación se hace con SQL:

```sql
-- 1) revisar lo que se va a publicar
select sku_code, model, color_en, finish_en, sample_size_en, available, validation_status
  from public.stock_overview where sku_code in ('HOUSTON2-001','HOUSTON2-002');
-- 2) publicar los SKU validados
update public.sample_skus set public_enabled = true, catalog_verified = true
 where code in ('HOUSTON2-001','HOUSTON2-002');
```
Mientras no haya fotos validadas cargadas, el catálogo no mostrará variantes (ajuste `require_validated_image = true`).
Para un piloto sin fotos (se mostraría "Photo coming soon"), es una decisión de CESANTONI:
`update public.settings set value = 'false' where key = 'require_validated_image';`
