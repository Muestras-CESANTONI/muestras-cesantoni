# Etapa 1 · Diagnóstico y respaldo

Fecha: 2026-11-04. Fuentes revisadas: repositorio `samples-cesantoni/samples-cesantoni.github.io` (commit `dea7837`, 17 commits, versión publicada `15`), Google Drive del propietario (lectura) y las dos bases de Sheets exportadas a .xlsx.

**No se pudieron abrir desde este entorno** (la red del entorno los bloquea): `samples-cesantoni.github.io`, `cesantoni-sample-studio-fr…chatgpt.site`, `cesantoni.com.mx`. El diagnóstico de la plataforma publicada se hizo con su código fuente; el catálogo de ChatGPT y las fotos oficiales **no** se revisaron.

## 1. Arquitectura actual

| Pieza | Tecnología | Estado real |
|---|---|---|
| Formulario público de muestras | Formulario web → hoja **REQUESTS** de «Base Sample Request CESANTONI - English» (Apps Script externo, no está en el repositorio) | Opera: 12 folios SMCES-0001…0012, `NEXT_NUMBER = 13` |
| Plataforma del equipo | GitHub Pages + Firebase Auth + Firestore (`sc_*`), proyecto compartido `proveedores-cesantoni` (plan gratuito) | Opera |
| Sincronización | Apps Script `Samples.gs` (cada 15 min), descargado de GitHub por `Cargador.gs` | Opera según su código; no se pudo ver su registro de ejecución |
| Correos a clientes | Gmail vía Apps Script «Correo proveedores CESANTONI» + EmailJS de respaldo | Depende de una sesión abierta **o** del Apps Script; modo PRUEBA/PRODUCCIÓN |
| Evidencias | Fotos **dentro de Firestore** en partes (límite 1 GiB compartido con otros 2 sistemas) | Opera, con riesgo de capacidad |
| Rastreo UPS | Lectura de avisos de UPS en Gmail + API de UPS si hay credenciales | Parcial (sin credenciales confirmadas) |
| Copia a «Base Sample Evidence & Costs» | `volcarSalida()` | **Apagado** (`ESCRIBIR_EN_BASE: false`); la hoja contiene una copia del 28-oct |

## 2. ¿Quién escribe en el inventario hoy? (riesgo de doble descuento)

Hay **dos escritores** del inventario y el código ha cambiado de criterio varias veces en 10 días (commits `b6c5e15`, `e2c5e15`, `98a13d7`, `fece2be`):

1. La hoja **PRODUCTS** (bloque «INVENTARIO OFICIAL») + **MOVIMIENTOS INVENTARIO**: el proceso del formulario descuenta cada folio al llegar.
2. La plataforma (Firestore `sc_inventario`): según `LEEME.md`, si la hoja trae el bloque oficial, la plataforma copia la existencia de la hoja; si no, descuenta por su cuenta.

Además existen ajustes manuales («AJUSTE MANUAL», «ALTA MANUAL») hechos directo en la hoja. **Conclusión:** durante la transición sólo un sistema debe descontar. La nueva base no descontará nada de los folios antiguos (se importan sin reservas) y, a partir del corte, el formulario anterior debe apagarse (ver plan de corte).

## 3. Componentes

### Se aprovechan
- Identidad visual: logos CESANTONI (blanco y color), tipografías Montserrat y Figtree (licencia SIL), paleta de la plataforma.
- Formato de folio `SMCES-0001` (4 dígitos) y secuencia: los folios nuevos continúan después del último importado, sin colisión.
- Reglas de negocio ya probadas en operación: Master por caja / JR por producto, estatus automáticos, carga masiva de evidencias por carpeta de folio, tarjetas en inglés para clientes.
- Destinatarios internos configurados (`INTERNAL_EMAIL`, 7 correos de cesantoni.com.mx y armexlogistics.com) para el aviso de solicitud nueva.
- Inventario Houston: 171 referencias con modelo, color, acabado, tamaño, tipo y ubicación.

### Deben corregirse
- **Permisos en el navegador**: la configuración de Firebase es pública por diseño, pero roles y reglas de negocio (descuentos, estatus) se ejecutan en JavaScript del cliente; las reglas de Firestore no pueden garantizar transacciones de inventario multi-documento.
- **Hoja USERS** con hashes SHA-256 sin sal de códigos de acceso dentro de una hoja compartida: deben retirarse.
- **Datos de inventario**: sin SKU (columna vacía), valor numérico «65» en COLOR (14 filas), 6 referencias sin ubicación, 3 posiciones usadas por dos referencias (B·1.1, B·2.1, C·2.1: el archivo guarda la posición como número y 1.10 probablemente se volvió 1.1), nombres duplicados (CASA BLANCA/CASABLANCA, DAYTONA ESTR/DAYTONA ESTRUCTURADO), 19 referencias de 7.5×30 (CHARLOT, EDIMBURGO, COTTO LORETO…) marcadas como «20×20 CUT» en el bloque de catálogo.
- **Estatus contradictorios** entre fuentes: hoja = SMCES-0004 RECEIVED; Firestore (copia 28-oct) = DELIVERED con la misma guía que SMCES-0005; SMCES-0006 «Ready for pickup» con guía UPS.
- **Solicitudes** con modelo/color de formulario que no coinciden con el inventario (p. ej. «ALPES GRIP · HUESO» frente a «ALPES · (sin color) · GRIP»).
- Correos y estatus automáticos que dependen de que haya una sesión abierta o de activadores de Apps Script.

### Deben desarrollarse (y ya se desarrollaron en esta entrega a nivel de base y área pública)
- Base PostgreSQL con restricciones, transacciones, bitácoras inmutables, idempotencia y auditoría.
- Reservas (Disponible = Física − Reservada), salida física única por modalidad, cancelaciones, devoluciones, conteos con revisión, cargas masivas con vista previa y detección de cambios.
- Cola de notificaciones en servidor con reintentos y deduplicación.
- Catálogo público conectado, `/request`, `/track` con token.
- Pendiente: panel interno nuevo (inventario, ARMEX, etiquetas PDF/QR, facturación, usuarios, dashboard) — ver «Siguientes etapas».

## 4. Accesos o servicios que realmente faltan

| Necesidad | Para qué | Quién |
|---|---|---|
| Proyecto **Supabase** (plan Pro recomendado: respaldos diarios y PITR opcional) o acceso para crearlo | Base, Auth, almacenamiento privado, funciones, cron | CESANTONI |
| Proveedor de correo con dominio verificado (recomendado **Resend**; DNS SPF/DKIM de un subdominio, p. ej. `samples.cesantoni.com.mx`) | Correos desde el servidor | TI de CESANTONI (DNS) |
| Exportación actual de Firestore `sc_*` (o acceso de lectura al proyecto `proveedores-cesantoni`) | Conciliar estatus, guías, costos y evidencias de los folios antiguos | Propietario de Firebase |
| Fotografías oficiales por variante (o permiso de red a `cesantoni.com.mx`) | Imágenes verificadas | CESANTONI |
| Código o acceso al catálogo `cesantoni-sample-studio-fr…chatgpt.site` | Conservar exactamente su diseño | Propietario |
| Permiso de escritura en GitHub (o un repositorio nuevo) | Publicar | Propietario |

## 5. Respaldos realizados (verificados)

Ubicación local del entorno: `/home/user/samples-cesantoni/backups/2026-11-04/` (contiene datos personales: **no** se sube al repositorio).

| Archivo | Verificación |
|---|---|
| `Base_Sample_Request_CESANTONI_English.xlsx` | sha256 `17de1e57…ab94`; abre con openpyxl; 11 hojas |
| `Base_Sample_Evidence_Costs_CESANTONI_English.xlsx` | abre; 15 hojas |
| `samples-cesantoni.github.io_dea7837.bundle` | `git bundle verify` OK (historial completo) |

Drive ya contiene respaldos previos del propietario: «CESANTONI Respaldo implementación 2026-11-03 – Solicitudes e inventario» y «– Evidencias y costos».
Restaurar código: `git clone samples-cesantoni.github.io_dea7837.bundle`. Restaurar hojas: subir el .xlsx a Drive → «Abrir con Hojas de cálculo».

## 6. Riesgos de migración

1. **Doble descuento** si el formulario anterior sigue recibiendo solicitudes después del corte → apagarlo el mismo día y redirigir su enlace.
2. **Saldos no contados**: los 7,061 pzs importados vienen de un archivo, no de un conteo → quedan «pendientes de validación física».
3. **Estatus antiguos** contradictorios → conciliación con exportación de Firestore antes del corte.
4. **Colisión de folios**: el formulario anterior sigue numerando; la secuencia nueva se sincroniza con `folio_sequence_sync()` en el corte.
5. **Imágenes**: ninguna foto verificada todavía → por defecto el catálogo público no publica variantes sin foto validada.
6. **Capacidad Firebase**: las evidencias actuales viven en Firestore; migrarlas requiere su exportación.

## 7. Orden de implementación

1. ✅ Respaldo + diagnóstico.
2. ✅ Base de datos e inventario (probado localmente).
3. ✅ Migración inicial reproducible con reporte.
4. ✅ Catálogo público, solicitud y seguimiento (probado localmente con navegador).
5. ⏳ Crear proyecto Supabase, aplicar migraciones, cargar datos, configurar secretos (requiere accesos).
6. ⏳ Panel interno: inventario → solicitudes/ARMEX → etiquetas Master/JR + QR → evidencias/incidencias → facturación → usuarios → dashboard.
7. ⏳ Correos con destinatarios autorizados en modo prueba; después producción.
8. ⏳ Conciliación final, fecha de corte, capacitación, apagado del flujo anterior.
