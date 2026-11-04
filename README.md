# CESANTONI · ARMEX — Samples Platform (v2)

Una sola plataforma con base central PostgreSQL (Supabase): catálogo público en inglés, solicitudes con reserva automática, seguimiento seguro, operación ARMEX, facturación y auditoría.

| Carpeta | Contenido |
|---|---|
| `supabase/migrations/` | Esquema versionado: tablas, restricciones, RLS, funciones de inventario/solicitudes/operación/facturación, cola de notificaciones, catálogo y seguimiento públicos |
| `supabase/functions/` | Edge Functions: `submit-request`, `notify-worker`, `email-webhook` (+ `_shared`) |
| `supabase/deploy/cron.sql` | Programación del procesador de correos (cada minuto) |
| `migration/` | Migración reproducible del Excel Houston → base, con reporte (`out/` no se versiona: contiene datos personales) |
| `index.html`, `request/`, `track/`, `assets/`, `config.js` | Área pública (GitHub Pages publica la raíz del repositorio): `/` catálogo, `/request`, `/track` |
| `tests/` | Pruebas de base (`db.test.mjs`) y de navegador (`e2e.mjs`) |
| `scripts/` | Base local de pruebas, servidor local, respaldo/restauración verificada, ejecución de todas las pruebas |
| `docs/` | Diagnóstico, arquitectura, despliegue y procedimientos |

## Probar localmente

```bash
node --experimental-strip-types scripts/dev_server.ts &
XLSX=<respaldo .xlsx> scripts/test_all.sh
```

Requiere PostgreSQL 16, Node 22 y Playwright (preinstalados en el entorno de desarrollo).
