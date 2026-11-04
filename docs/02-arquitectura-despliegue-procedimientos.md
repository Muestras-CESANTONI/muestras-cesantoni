# Arquitectura, despliegue y procedimientos

## Arquitectura elegida

```
            Clientes (inglés)                                Equipo (CESANTONI · ARMEX · Facturación)
  /  catálogo · /request · /track                                  /admin  (pendiente: Etapas 5–7)
              │  anon key (sólo lectura filtrada)                          │ sesión Supabase Auth (correo)
              ▼                                                            ▼
  Edge Function submit-request ──► PostgreSQL (Supabase) ◄── funciones SQL con permisos por rol
   (validación, anti-abuso,          • restricciones, transacciones, RLS
    token de seguimiento)            • movimientos / historial / auditoría inmutables
                                     • cola de notificaciones (outbox)
                                            │ pg_cron cada minuto
                                            ▼
                                Edge Function notify-worker ──► Resend (correo) ──► webhook entrega
  Almacenamiento: bucket privado «evidence», privado «invoices», público «catalog-images»
```

* **Por qué Supabase:** PostgreSQL administrado (transacciones, claves, restricciones, respaldos), Auth con invitaciones por correo, almacenamiento privado con URLs firmadas, funciones de servidor y cron en el mismo proyecto. El frontend sigue siendo estático (GitHub Pages actual u otro hosting HTTPS).
* **Ninguna escritura sale del navegador directo a tablas.** El navegador sólo llama funciones SQL `SECURITY DEFINER` que verifican el perfil activo del usuario en la base (`app.require_role`). Las tablas tienen RLS forzado.
* Excel queda sólo para migración, cargas controladas (`import_preview` → `import_apply`) y exportaciones.

### Reglas de inventario implementadas en la base
| Regla | Dónde |
|---|---|
| Disponible = física − reservada; nada negativo; reservada ≤ física | `CHECK` en `stock` + `app.stock_change` |
| Solicitud aceptada reserva automáticamente | `submit_request` → `app.reserve_line` |
| Salida física: `shipped` (paquetería) o `collected` (recolección); consume la reserva una sola vez | `request_set_status` → `app.ship_reservations` |
| Cancelación antes de la salida libera; después no repone | `request_set_status('cancelled')` |
| Devolución sólo con fecha de recepción y condición confirmada | `inv_return_receipt` |
| Conteo menor a reservas → «review», no se aplica | `inv_count`, `import_preview` |
| No se borran movimientos | trigger `append_only` |
| Doble clic / reintentos / concurrencia | `operations.op_id` + bloqueo de filas en orden |
| Carga Excel: conteo absoluto ≠ entrada; si el inventario cambió tras la vista previa se detiene; un archivo no se aplica dos veces | `import_preview` / `import_apply` |

### Estatus
`submitted → reserved → in_preparation → ready → shipped → delivered` (paquetería) · `ready → ready_for_pickup → collected` (recolección) · `on_hold` regresa al estatus anterior · `cancelled`.
Requisitos: `ready` exige bultos que cubran todas las piezas; `shipped` exige guía; `collected` exige comprobante; `delivered` exige envío. Sólo un administrador puede registrar una excepción, con motivo (queda `is_exception = true`). Cada cambio guarda fecha del evento y fecha de registro (`retroactive` si difieren > 15 min).

### Folios
`SMCES-` + número con 4 dígitos mínimo (formato existente). Se generan con una secuencia de PostgreSQL dentro de la transacción (nunca en el navegador ni con `max()+1`). Un intento fallido puede dejar un hueco en la numeración; nunca un duplicado. La consulta pública exige el token secreto del enlace (HMAC-SHA256 truncado a 48 caracteres hex = 192 bits); el folio solo no revela nada.

## Despliegue (cuando existan los accesos)

1. **Supabase**: crear proyecto (región us-east o us-central). En *Settings › API* copiar URL, anon key y service key (la service key **nunca** va al repositorio ni al navegador).
2. Aplicar migraciones en orden: `supabase db push` (o pegar cada archivo de `supabase/migrations/` en el SQL editor).
3. Migración inicial: `python3 -I migration/migrate_houston.py <xlsx respaldado> migration/out` y ejecutar `migration/out/load.sql` con la cadena de conexión directa. Revisar `migration/out/report.md`.
4. Secretos de funciones (*Edge Functions › Secrets*): `TRACKING_SECRET`, `FINGERPRINT_SALT`, `WORKER_SECRET` (valores aleatorios de 32+ bytes), `ALLOWED_ORIGINS`, `PUBLIC_SITE_URL`, `RESEND_API_KEY`, `MAIL_FROM`, `MAIL_REPLY_TO`, `MAIL_MODE=test`, `MAIL_TEST_RECIPIENTS`, `RESEND_WEBHOOK_SECRET`, `TURNSTILE_SECRET` (opcional).
5. `supabase functions deploy submit-request --no-verify-jwt`, `notify-worker --no-verify-jwt`, `email-webhook --no-verify-jwt` (cada una valida su propio secreto/origen).
6. Ejecutar `supabase/deploy/cron.sql` (una vez).
7. Usuarios: *Authentication › Users › Invite* para cada persona; luego `select public.user_set_profile(<uid>, <correo>, <nombre>, 'CESANTONI'|'ARMEX', 'admin'|'cesantoni'|'armex'|'billing', true)`. La hoja USERS lista 2 administradores, 1 usuario CESANTONI y 2 de ARMEX; confirmar roles antes de invitar.
8. Frontend: copiar `web/` al hosting, crear `config.js` desde `config.example.js`.
9. **Entornos separados**: un proyecto Supabase de pruebas y otro de producción, con secretos distintos; las migraciones se aplican primero en pruebas.

## Procedimiento: actualizar inventario

* **Entrada de mercancía** (llegaron muestras): *Inventario › Entrada* → SKU, ubicación, cantidad, motivo → `inv_receive`. Suma a la existencia física.
* **Conteo** de un SKU: *Inventario › Conteo* → cantidad contada → `inv_count`. Si es menor que lo reservado no se aplica y aparece en revisión. Marca el SKU como validado físicamente.
* **Ajuste justificado** (+/−, p. ej. pieza rota): `inv_adjust` con motivo. Sólo CESANTONI/administrador.
* **Cambio de ubicación**: `inv_relocate` (sólo piezas disponibles).
* **Conteo masivo por Excel** (columnas `sku_code, furniture, position, quantity`): seleccionar archivo → vista previa con saldo actual, propuesto y diferencia → motivo → aplicar. Si alguien movió inventario mientras tanto, la aplicación se detiene («stale») y se genera una vista previa nueva. Un mismo archivo no puede aplicarse dos veces. Nunca borra reservas, pedidos ni historial.

## Procedimiento: respaldar y recuperar

* **Automático (Supabase Pro):** respaldo diario de 7 días; PITR opcional. Restaurar desde *Database › Backups*.
* **Lógico propio (recomendado semanal y antes de cada cambio grande):**
  `SOURCE_URL=<conexión producción> RESTORE_URL=<base de pruebas vacía> scripts/backup_restore_check.sh <carpeta>`
  Genera `samples_<fecha>.dump` (esquemas `public` y `app`) + `…_auth_users.sql` + `.sha256`, lo restaura en la base de pruebas y compara SKU, piezas, reservas, movimientos, solicitudes, líneas y auditoría. Resultado comprobado localmente: `RESTORE OK` con conteos idénticos.
* **Archivos** (evidencias, facturas): descargar los buckets con `supabase storage cp -r ss:///evidence <carpeta>` en la misma rutina.
* **Recuperar**: crear proyecto/base vacía → aplicar `…_auth_users.sql` → `pg_restore --use-list` (sin el esquema `public`) → verificar conteos → apuntar `config.js` y secretos al proyecto restaurado.

## Plan de corte (transición sin dos sistemas descontando)

1. Congelar: anunciar fecha/hora de corte (sugerido: fin de día, sin envíos en curso).
2. Exportar la hoja y Firestore; volver a correr `migrate_houston.py` sobre el archivo final.
3. Conteo físico de las posiciones con observaciones (mínimo) o total (ideal) y carga como «conteo absoluto».
4. Conciliar estatus de los folios antiguos con Firestore; registrar diferencias.
5. Apagar el formulario anterior y los activadores de `Samples.gs` (`sincronizar`, `rastreo`, `recordatorios`); redirigir el enlace público al nuevo `/request`.
6. `select public.folio_sequence_sync();` y comprobar el siguiente folio.
7. Correos en modo prueba con destinatarios autorizados → validar plantillas → `MAIL_MODE=production`.
8. Mantener la plataforma anterior en sólo lectura 30 días.
