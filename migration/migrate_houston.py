#!/usr/bin/env python3
"""
Initial migration: «Base Sample Request CESANTONI - English» (.xlsx export) → PostgreSQL.

Reads ONLY the backup file (never the live sheet) and writes:
  out/load.sql           one transaction: catalog, locations, stock (initial_load), legacy requests,
                         legacy movements (history only), legacy references, notification recipients
  out/report.md          human report (imported / rejected / pending validation / conflicts)
  out/*.csv              detail per section

Rules applied (from the project brief):
  * The official block «INVENTARIO OFICIAL» of PRODUCTS is the source. The CATALOG block of the same sheet
    and «SYNC CATALOG RAW» are projections of the same rows → compared, never added.
  * The source has no SKU codes (column «SKU (OMITIDO)» is empty); the unique reference HOUSTON2-### is used
    as the sample SKU code. Uniqueness is validated.
  * Balances are imported as «pending physical validation» (no evidence of a recent count).
  * Legacy references without data (EXP-xxxx) go to legacy_references, never to stock.
  * Nothing is invented: unknown product formats, colors or locations stay NULL and are reported.
  * Legacy requests are imported WITHOUT reservations or movements: the legacy sheet already deducted them,
    so importing them again would deduct twice.

Usage: python3 -I migrate_houston.py <Base_Sample_Request.xlsx> <out_dir>
"""
import csv, hashlib, json, os, re, secrets, sys, datetime as dt
from collections import Counter, defaultdict
import openpyxl

SRC, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
sha = hashlib.sha256(open(SRC, 'rb').read()).hexdigest()
wb = openpyxl.load_workbook(SRC, data_only=True)

def q(v):
    """SQL literal."""
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"

def norm(v):
    return re.sub(r'\s+', ' ', str(v).strip()).upper() if v not in (None, '') else None

# Generic Spanish color words → English PROPOSAL (catalog_verified stays false until CESANTONI confirms).
# Brand-like color names (PLATINO, OZARK, COHIBA…) are kept as written.
COLOR_EN = {'BLANCO': 'White', 'NEGRO': 'Black', 'GRIS': 'Gray', 'HUESO': 'Bone', 'MARFIL': 'Ivory',
            'TAUPÉ': 'Taupe', 'TERRACOTA': 'Terracotta'}

def color_en(c):
    return COLOR_EN.get(c, c.title()) if c else None

def jdefault(o):
    return o.isoformat() if isinstance(o, (dt.date, dt.datetime)) else str(o)

def jq(o):
    return q(json.dumps(o, ensure_ascii=False, default=jdefault)) + '::jsonb'

report = defaultdict(list)   # section -> rows
issues = []                  # (severity, ref, message)

# ------------------------------------------------------------------ PRODUCTS: official block
ws = wb['PRODUCTS']
rows = list(ws.iter_rows(values_only=True))
hdr_row = next(i for i, r in enumerate(rows) if r and 'REFERENCIA' in [str(x).strip() if x else '' for x in r])
H = [str(x).strip() if x else '' for x in rows[hdr_row]]
off = H.index('FUENTE')                    # official block starts at FUENTE
OH = H[off:]
cat_cols = H[:off]

def oget(r, name, nth=0):
    idx = [i for i, h in enumerate(OH) if h == name][nth]
    return r[off + idx]

def cget(r, name):
    return r[cat_cols.index(name)]

items, legacy_refs = [], []
for i, r in enumerate(rows[hdr_row + 1:], start=hdr_row + 2):
    ref = oget(r, 'REFERENCIA')
    if not ref:
        continue
    ref = str(ref).strip().upper()
    rec = {
        'excel_row': i, 'source': oget(r, 'FUENTE'), 'source_file_row': oget(r, 'FILA EXCEL'),
        'ref': ref, 'model': norm(oget(r, 'MODELO')), 'color_raw': oget(r, 'COLOR'), 'finish': norm(oget(r, 'ACABADO')),
        'qty_raw': oget(r, 'INVENTARIO'), 'size': oget(r, 'TAMAÑO DE MUESTRA'),
        'cut': oget(r, 'MUESTRA / CUT'), 'std': oget(r, 'STANDARD'), 'status_src': oget(r, 'ESTATUS'),
        'cat_show': cget(r, 'MOSTRAR'), 'cat_qty': cget(r, 'INVENTARIO'), 'cat_ref': cget(r, 'REFERENCIA FUENTE'),
        'cat_type': cget(r, 'TIPO DE MUESTRA'), 'cat_location': cget(r, 'UBICACIÓN'), 'cat_label': cget(r, 'ETIQUETA WEB'),
        'cat_sku': cget(r, 'SKU (OMITIDO)'),
    }
    # legacy references (e.g. EXP-0079): the code sits in MODELO and there is no finish nor size
    if not rec['model'] or (not rec['finish'] and not rec['size'] and rec['model'] == ref):
        legacy_refs.append(rec)
        continue
    items.append(rec)

# uniqueness of the reference used as SKU code
dups = [k for k, v in Counter(x['ref'] for x in items).items() if v > 1]
for d in dups:
    issues.append(('ERROR', d, 'Reference duplicated: rows rejected'))

imported, rejected = [], []
locations = {}
pos_use = Counter()
for x in items:
    flags = []
    if x['ref'] in dups:
        x['reject'] = 'Duplicated reference'; rejected.append(x); continue
    # quantity
    try:
        qty = int(float(x['qty_raw']))
        if qty < 0 or float(x['qty_raw']) != qty:
            raise ValueError
    except (TypeError, ValueError):
        x['reject'] = f"Invalid quantity {x['qty_raw']!r}"; rejected.append(x); continue
    x['qty'] = qty
    if not x['finish']:
        x['reject'] = 'Finish missing'; rejected.append(x); continue
    # sample type
    if x['cut'] is True and x['std'] is not True:
        x['sample_type'] = 'cut_sample'
    elif x['std'] is True and x['cut'] is not True:
        x['sample_type'] = 'full_piece'
    else:
        x['reject'] = 'Sample type ambiguous (MUESTRA/CUT and STANDARD)'; rejected.append(x); continue
    if not x['size']:
        x['reject'] = 'Sample size missing'; rejected.append(x); continue
    # color: a bare number (e.g. 65) is not a color → stored as NULL, raw kept
    c = x['color_raw']
    if c is None or str(c).strip() == '':
        x['color'] = None
    elif re.fullmatch(r'\d+(\.\d+)?', str(c).strip()):
        # kept as written (it distinguishes rows, e.g. two SAMPERI 7.5x30) but with no public color name
        x['color'] = str(int(float(c)))
        x['color_unclear'] = True
        flags.append(f'COLOR has a bare number ({c}): kept as source value, no English color name — confirm what it means')
    else:
        x['color'] = norm(c)
    # catalog block must mirror the official block (same row) — compare, never add
    if str(x['cat_ref'] or '').strip().upper() != x['ref']:
        flags.append(f"Catalog block reference differs ({x['cat_ref']})")
    if x['cat_qty'] is not None and float(x['cat_qty']) != qty:
        flags.append(f"Catalog block quantity differs ({x['cat_qty']} vs {qty})")
    if x['cat_type'] == '20×20 CUT' and not str(x['size']).startswith('20*20'):
        flags.append(f"Catalog type says '20×20 CUT' but sample size is {x['size']}: confirm sample type and size")
    if x['cat_sku']:
        flags.append(f"Catalog SKU column has a value ({x['cat_sku']}) — not used")
    # location
    loc = None
    m = re.match(r'^\s*Mueble\s+([A-Z0-9]+)\s*·\s*Pos\.\s*([0-9.]+)\s*$', str(x['cat_location'] or ''), re.I)
    if m:
        loc = (m.group(1).upper(), m.group(2))
        pos_use[loc] += 1
    elif x['cat_location']:
        flags.append(f"Location not understood: {x['cat_location']!r}")
    else:
        flags.append('No location assigned')
    x['loc'] = loc
    if x['status_src'] == 'PENDIENTE':
        flags.append('Source status PENDIENTE (pending in the Houston file)')
    if qty == 0:
        flags.append('Zero balance')
    x['flags'] = flags
    imported.append(x)

for x in imported:
    if x['loc'] and pos_use[x['loc']] > 1:
        x['flags'].append(f"Location Mueble {x['loc'][0]} · Pos. {x['loc'][1]} used by {pos_use[x['loc']]} references "
                          "(the file stores positions as numbers: 1.10 may have become 1.1) — validate physically")

# possible naming aliases (reported, not merged)
models = sorted({x['model'] for x in imported})
alias = []
def _abbrev(a, b):
    wa, wb_ = a.split(), b.split()
    return len(wa) == len(wb_) and a != b and all(y.startswith(x) for x, y in zip(wa, wb_))
for a in models:
    for b in models:
        if a < b and (a.replace(' ', '').replace('-', '') == b.replace(' ', '').replace('-', '') or _abbrev(a, b) or _abbrev(b, a)):
            alias.append((a, b))
for a, b in alias:
    issues.append(('REVIEW', f'{a} / {b}', 'Possible same model written two ways — not merged automatically'))

# ------------------------------------------------------------------ legacy requests
wr = wb['REQUESTS']
rr = list(wr.iter_rows(values_only=True))
hi = next(i for i, r in enumerate(rr) if r and 'FOLIO' in r)
RH = [str(x).strip() if x else '' for x in rr[hi]]
req_lines = defaultdict(list)
for i, r in enumerate(rr[hi + 1:], start=hi + 2):
    d = dict(zip(RH, r))
    if d.get('FOLIO'):
        d['_row'] = i
        req_lines[str(d['FOLIO']).strip()].append(d)

wm = wb['MOVIMIENTOS INVENTARIO']
mr = list(wm.iter_rows(values_only=True))
mi = next(i for i, r in enumerate(mr) if r and 'PROCESO' in r)
MH = [str(x).strip() if x else '' for x in mr[mi]]
movs = []
for i, r in enumerate(mr[mi + 1:], start=mi + 2):
    d = dict(zip(MH, r))
    if any(v not in (None, '') for v in r):
        d['_row'] = i
        movs.append(d)
mov_by_folio = defaultdict(list)
for d in movs:
    if d.get('FOLIO'):
        mov_by_folio[str(d['FOLIO']).strip()].append(d)

by_ref = {x['ref']: x for x in imported}
by_loc_model = {(f'Mueble {x["loc"][0]} · Pos. {x["loc"][1]}', x['model']): x for x in imported if x['loc']}
STATUS_MAP = {'RECEIVED': 'reserved', 'PREPARING': 'in_preparation', 'PREPARED': 'ready', 'READY_FOR_PICKUP': 'ready_for_pickup',
              'SHIPPED': 'shipped', 'IN_TRANSIT': 'shipped', 'DELIVERED': 'delivered', 'ON_HOLD': 'on_hold', 'CANCELLED': 'cancelled'}

legacy_requests = []
for folio, lines in sorted(req_lines.items()):
    h = lines[0]
    ms = mov_by_folio.get(folio, [])
    out_lines = []
    for k, ln in enumerate(lines):
        ref, how = None, None
        mv = ms[k] if len(ms) == len(lines) else None
        lm = norm(ln.get('MODELO')) or ''
        if mv is not None:
            mref = str(mv.get('REFERENCIA') or '').strip()
            mmodel = norm(mv.get('MODELO')) or ''
            if mmodel.split(' ')[0] != lm.split(' ')[0]:
                mv = None
            elif mref.upper() in by_ref:
                ref, how = mref.upper(), 'legacy movement reference'
            elif (mref, mmodel) in by_loc_model:
                ref, how = by_loc_model[(mref, mmodel)]['ref'], 'legacy movement location + model'
            elif not mref and float(mv.get('CANTIDAD') or 0) > 0:
                cands = [x for x in imported if x['model'] == mmodel and x['sample_type'] == 'full_piece']
                if len(cands) == 1:
                    ref, how = cands[0]['ref'], 'unique full piece of the model (no reference in legacy movement)'
        out_lines.append({'line_no': int(ln.get('LÍNEA') or k + 1), 'model': lm, 'color': ln.get('COLOR'),
                          'size': ln.get('TAMAÑO / TIPO DE MUESTRA'), 'qty': int(float(ln.get('NÚM. DE PIEZAS') or 0)),
                          'ref': ref, 'match': how or 'NOT MATCHED', 'raw': ln})
        if not ref:
            issues.append(('REVIEW', f'{folio} line {k + 1}', f'Legacy line {lm} / {ln.get("COLOR")} / {ln.get("TAMAÑO / TIPO DE MUESTRA")} not matched to a SKU (kept as text)'))
    st = str(h.get('ESTATUS (CÓDIGO)') or 'RECEIVED').strip().upper()
    legacy_requests.append({'folio': folio, 'number': int(folio.split('-')[1]), 'status_src': st, 'status': STATUS_MAP.get(st, 'on_hold'),
                            'h': h, 'lines': out_lines})

# ------------------------------------------------------------------ configuration (recipients)
cfg = {str(r[0]).strip(): r[1] for r in wb['CONFIGURATION'].iter_rows(values_only=True) if r and r[0]}
internal = [e.strip().lower() for e in str(cfg.get('INTERNAL_EMAIL') or '').split(',') if e.strip()]
next_number = int(float(cfg.get('NEXT_NUMBER') or 0))

# ------------------------------------------------------------------ SQL
S = []
w = S.append
w('-- Generated by migration/migrate_houston.py — DO NOT EDIT BY HAND')
w(f'-- source file sha256 {sha}')
w('begin;')
w("select set_config('request.jwt.claim.role', 'service_role', true);")
w("select set_config('app.actor_label', 'migration:houston-initial', true);")
w("set local role service_role;")
op = '00000000-0000-4000-8000-' + sha[:12]
w(f"insert into public.operations (op_id, kind, actor_label) values ('{op}', 'initial_migration', 'migration:houston-initial');")
w(f"insert into public.imports (kind, file_name, file_sha256, status, reason, rows_total, rows_valid, rows_rejected, summary, created_by_label, applied_at, apply_op_id) "
  f"values ('initial_migration', {q(os.path.basename(SRC))}, '{sha}', 'applied', 'Initial load from Houston inventory (PRODUCTS · INVENTARIO OFICIAL)', "
  f"{len(items) + len(legacy_refs)}, {len(imported)}, {len(rejected) + len(legacy_refs)}, "
  f"{jq({'source_sheet': 'PRODUCTS', 'block': 'INVENTARIO OFICIAL', 'duplicated_blocks_not_added': ['PRODUCTS · CATÁLOGO', 'Evidence base · SYNC CATALOG RAW'], 'legacy_refs': len(legacy_refs)})}, "
  f"'migration:houston-initial', now(), '{op}');")
w("create temp table _imp as select currval('public.imports_id_seq') as id;")

for m in models:
    cat = 'paver' if ' PAVER' in m or m.endswith('PAVER') else 'tile'
    w(f"insert into public.products (model, display_name_en, category) values ({q(m)}, {q(m.title())}, '{cat}') on conflict (model) do nothing;")
for (fur, pos) in sorted(pos_use):
    w(f"insert into public.locations (warehouse_id, furniture, position) select id, {q(fur)}, {q(pos)} from public.warehouses where code = 'HOUSTON' on conflict do nothing;")

for x in imported:
    size = str(x['size']).strip()
    size_en = re.sub(r'^.*/\s*', '', size).replace('X', 'x').replace(' x ', 'x').strip()  # '20*20 CM / 8x8 IN' → '8x8 IN'
    size_en = size_en.replace('IN', 'in').replace(' in', ' in')
    label = (size_en + (' cut sample' if x['sample_type'] == 'cut_sample' else ' full piece')).replace('  ', ' ')
    w(f"insert into public.variants (product_id, color_source, color_en, finish_code) "
      f"select id, {q(x['color'])}, {q(color_en(x['color']) if x['color'] and not x.get('color_unclear') else None)}, {q(x['finish'])} from public.products where model = {q(x['model'])} "
      f"on conflict do nothing;")
    w(f"insert into public.sample_skus (code, variant_id, sample_type, sample_size, sample_size_en, max_per_request, public_enabled, catalog_verified, source_ref) "
      f"select {q(x['ref'])}, v.id, '{x['sample_type']}', {q(size)}, {q(label)}, {1 if x['sample_type'] == 'full_piece' else 10}, false, false, {q(x['ref'])} "
      f"from public.variants v join public.products p on p.id = v.product_id "
      f"where p.model = {q(x['model'])} and coalesce(v.color_source, '') = {q(x['color'] or '')} and v.finish_code = {q(x['finish'])} and v.product_format is null;")
    locsql = (f"(select l.id from public.locations l join public.warehouses w on w.id = l.warehouse_id where w.code = 'HOUSTON' "
              f"and l.furniture = {q(x['loc'][0])} and l.position = {q(x['loc'][1])})") if x['loc'] else 'null'
    w(f"insert into public.stock (sku_id, location_id, on_hand, reserved, validation_status) "
      f"select id, {locsql}, 0, 0, 'pending_physical_validation' from public.sample_skus where code = {q(x['ref'])};")
    if x['qty'] > 0:
        w(f"select app.stock_change((select s.id from public.stock s join public.sample_skus k on k.id = s.sku_id where k.code = {q(x['ref'])}), "
          f"'initial_load', {x['qty']}, 0, '{op}', {q('Initial load · ' + os.path.basename(SRC) + ' · PRODUCTS row ' + str(x['excel_row']) + ' · pending physical validation')}, "
          f"null, null, (select id from _imp));")
    w(f"insert into public.import_rows (import_id, row_no, raw, sku_code, location_label, proposed, difference, status, message) values "
      f"((select id from _imp), {x['excel_row']}, {jq({k: v for k, v in x.items() if k not in ('flags',)})}, {q(x['ref'])}, "
      f"{q(' · '.join(x['loc']) if x['loc'] else None)}, {x['qty']}, {x['qty']}, 'valid', {q('; '.join(x['flags']) or None)});")

for x in rejected:
    w(f"insert into public.import_rows (import_id, row_no, raw, sku_code, status, message) values ((select id from _imp), {x['excel_row']}, "
      f"{jq(x)}, {q(x['ref'])}, 'rejected', {q(x['reject'])});")
for x in legacy_refs:
    w(f"insert into public.legacy_references (reference, source, raw, note) values ({q(x['ref'])}, 'PRODUCTS row {x['excel_row']}', {jq(x)}, "
      f"'Reference without model/color/size in the Houston inventory: kept for reconciliation, not added to stock') on conflict (reference) do nothing;")
    w(f"insert into public.import_rows (import_id, row_no, raw, sku_code, status, message) values ((select id from _imp), {x['excel_row']}, "
      f"{jq(x)}, {q(x['ref'])}, 'rejected', 'Legacy reference without product data → legacy_references');")
for d in movs:
    w(f"insert into public.legacy_movements (source, source_row, folio, reference, raw) values ('MOVIMIENTOS INVENTARIO', {d['_row']}, "
      f"{q(d.get('FOLIO') or None)}, {q(str(d.get('REFERENCIA') or '') or None)}, {jq(d)});")

# legacy requests (no reservations / movements: already deducted in the legacy sheet)
for R in legacy_requests:
    h = R['h']
    tok = secrets.token_hex(32)   # not stored nor sent: legacy customers get a link only if CESANTONI re-sends it
    created = h.get('FECHA / HORA')
    created_sql = f"{q(created.isoformat())}::timestamp at time zone 'America/Mexico_City'" if isinstance(created, dt.datetime) else 'now()'
    addr = h.get('DIRECCIÓN')
    method = 'shipping'
    w(f"insert into public.requests (folio_number, folio, source, status, full_name, company, email, phone, delivery_method, "
      f"address_line, city, state, zip_code, country, delivery_notes, notes, tracking_token_hash, idempotency_key, created_at) values ("
      f"{R['number']}, {q(R['folio'])}, 'legacy_sheet', '{R['status']}', {q(str(h.get('NOMBRE COMPLETO') or '').strip() or 'Unknown')}, "
      f"{q(h.get('EMPRESA'))}, {q(str(h.get('CORREO') or '').strip().lower())}, {q(str(h.get('TELÉFONO') or '').strip() or 'n/a')}, '{method}', "
      f"{q(addr)}, {q(h.get('CIUDAD'))}, {q(h.get('ESTADO / PROVINCIA'))}, "
      f"{q(str(int(h['CÓDIGO POSTAL'])) if isinstance(h.get('CÓDIGO POSTAL'), (int, float)) else h.get('CÓDIGO POSTAL'))}, "
      f"{q(h.get('PAÍS'))}, {q(h.get('REFERENCIAS DE ENTREGA'))}, {q(h.get('NOTAS'))}, "
      f"'{hashlib.sha256(tok.encode()).hexdigest()}', gen_random_uuid(), {created_sql});")
    w(f"insert into public.request_status_history (request_id, from_status, to_status, reason, actor_label, op_id, occurred_at) "
      f"select id, null, '{R['status']}', {q('Imported from legacy sheet with status ' + R['status_src'] + ' (to be reconciled with the operational platform)')}, "
      f"'migration:houston-initial', '{op}', created_at from public.requests where folio = {q(R['folio'])};")
    for L in R['lines']:
        x = by_ref.get(L['ref']) if L['ref'] else None
        desc = ' · '.join(str(v) for v in (L['model'], L['color'], L['size']) if v)
        w(f"insert into public.request_lines (request_id, line_no, sku_id, quantity, snap_model, snap_color, snap_finish, snap_sample_size, "
          f"snap_sample_type, snap_description, legacy_raw) select r.id, {L['line_no']}, "
          f"{'(select id from public.sample_skus where code = ' + q(L['ref']) + ')' if x else 'null'}, {max(L['qty'], 1)}, {q(L['model'])}, "
          f"{q(L['color'])}, {q(x['finish'] if x else None)}, {q(L['size'])}, {q(x['sample_type'] if x else None)}, {q(desc)}, "
          f"{jq({'raw': L['raw'], 'match': L['match'], 'matched_ref': L['ref']})} from public.requests r where r.folio = {q(R['folio'])};")

# operational recipients from CONFIGURATION · INTERNAL_EMAIL (only for the "request received" event they were configured for)
for e in internal:
    org = 'CESANTONI' if e.endswith('@cesantoni.com.mx') else 'ARMEX' if e.endswith('@armexlogistics.com') else None
    if org:
        w(f"insert into public.notification_recipients (event, org_id, email) select 'request_confirmed', id, {q(e)} "
          f"from public.organizations where code = '{org}' on conflict do nothing;")
    else:
        issues.append(('REVIEW', e, 'Internal recipient with unknown organization — not loaded'))
w("select public.folio_sequence_sync();")
w("reset role;")
w('commit;')
open(os.path.join(OUT, 'load.sql'), 'w').write('\n'.join(S) + '\n')

# ------------------------------------------------------------------ reports
def wcsv(name, header, rows_):
    with open(os.path.join(OUT, name), 'w', newline='') as f:
        c = csv.writer(f); c.writerow(header); c.writerows(rows_)

wcsv('imported.csv', ['excel_row', 'sku_code', 'model', 'color', 'finish', 'sample_type', 'sample_size', 'quantity', 'furniture', 'position', 'validation', 'observations'],
     [[x['excel_row'], x['ref'], x['model'], x['color'], x['finish'], x['sample_type'], x['size'], x['qty'],
       x['loc'][0] if x['loc'] else '', x['loc'][1] if x['loc'] else '', 'pending_physical_validation', ' | '.join(x['flags'])] for x in imported])
wcsv('rejected.csv', ['excel_row', 'reference', 'reason', 'raw_model', 'raw_qty'],
     [[x['excel_row'], x['ref'], x['reject'], x['model'], x['qty_raw']] for x in rejected] +
     [[x['excel_row'], x['ref'], 'Legacy reference without product data (kept in legacy_references)', '', x['qty_raw']] for x in legacy_refs])
wcsv('legacy_request_lines.csv', ['folio', 'legacy_status', 'mapped_status', 'line', 'model', 'color', 'size', 'qty', 'matched_sku', 'match_method'],
     [[R['folio'], R['status_src'], R['status'], L['line_no'], L['model'], L['color'], L['size'], L['qty'], L['ref'] or '', L['match']]
      for R in legacy_requests for L in R['lines']])
wcsv('issues.csv', ['severity', 'subject', 'message'], issues)

tot = sum(x['qty'] for x in imported)
by_type = Counter()
for x in imported:
    by_type[x['sample_type']] += x['qty']
flagged = [x for x in imported if x['flags']]
md = f"""# Reporte de migración inicial · Inventario Houston

- Archivo: `{os.path.basename(SRC)}` (sha256 `{sha}`)
- Hoja / bloque: PRODUCTS · «INVENTARIO OFICIAL · Inventario inicial - Houston(2).xlsx»
- Fecha de generación: {dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}

## Resumen

| Concepto | Cantidad |
|---|---|
| Filas con referencia en el bloque oficial | {len(items) + len(legacy_refs)} |
| SKU importados | {len(imported)} |
| Filas rechazadas | {len(rejected)} |
| Referencias antiguas sin datos (a conciliación, no suman) | {len(legacy_refs)} ({', '.join(x['ref'] for x in legacy_refs)}) |
| SKU importados con observaciones | {len(flagged)} |
| Piezas físicas importadas · muestras de corte | {by_type['cut_sample']} |
| Piezas físicas importadas · piezas completas | {by_type['full_piece']} |
| Productos (modelos) | {len(models)} |
| Ubicaciones distintas | {len(pos_use)} |
| Solicitudes antiguas importadas (sin reservar ni descontar de nuevo) | {len(legacy_requests)} |
| Movimientos antiguos guardados como historial (no se aplican) | {len(movs)} |
| Destinatarios internos cargados (evento «solicitud confirmada») | {len([e for e in internal if e.endswith(('@cesantoni.com.mx', '@armexlogistics.com'))])} |
| Siguiente folio | SMCES-{max([R['number'] for R in legacy_requests] + [0]) + 1:04d} (la hoja indica NEXT_NUMBER = {next_number}) |

Todos los saldos quedan **pendientes de validación física** (no hay evidencia de un conteo reciente).
Ningún SKU queda publicado: `public_enabled = false` y `catalog_verified = false` hasta que CESANTONI valide nombre en inglés, color, acabado, tamaño e imagen.

## Duplicados detectados y NO sumados

- El bloque «CATÁLOGO» de PRODUCTS repite las mismas {len(items)} referencias que el bloque oficial: se comparó fila por fila y no se sumó.
- La hoja «SYNC CATALOG RAW» de la base de evidencias es una copia del catálogo: no se importó.
- Referencias duplicadas en el bloque oficial: {', '.join(dups) or 'ninguna'}.

## Observaciones que requieren revisión

""" + '\n'.join(f'- **{s}** · {sub}: {msg}' for s, sub, msg in issues) + """

## Observaciones por SKU

""" + '\n'.join(f"- `{x['ref']}` {x['model']} {x['color'] or ''} {x['finish']} · {x['size']} · {x['qty']} pzs: " + '; '.join(x['flags']) for x in flagged) + """

## Solicitudes antiguas

""" + '\n'.join(f"- {R['folio']}: estatus en la hoja `{R['status_src']}` → `{R['status']}`; líneas {len(R['lines'])}, "
               f"relacionadas con SKU {sum(1 for L in R['lines'] if L['ref'])}" for R in legacy_requests) + """

Las solicitudes antiguas no generan reservas ni movimientos: la hoja ya las descontó al recibirlas.
Su estatus debe conciliarse con la plataforma operativa (Firestore) antes del corte: ver diagnóstico.
"""
open(os.path.join(OUT, 'report.md'), 'w').write(md)
print(json.dumps({'imported': len(imported), 'rejected': len(rejected), 'legacy_refs': len(legacy_refs), 'flagged': len(flagged),
                  'pieces': dict(by_type), 'legacy_requests': len(legacy_requests), 'issues': len(issues)}, ensure_ascii=False))
