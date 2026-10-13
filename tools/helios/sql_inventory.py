#!/usr/bin/env python3
"""Inventory of SQL call sites in darktable sources (helios phase 0).

Scans src/ for statements handed to SQLite and classifies them by layer,
domain, tables and operation.  Used both as the map for the catalog SDK
refactor and as a CI guard (--check) forbidding SQL outside allowed paths.

usage: sql_inventory.py [--src DIR] [--json FILE] [--markdown FILE] [--check]
"""
import argparse, json, os, re, sys
from collections import Counter, defaultdict

CALLS = re.compile(r'\b(DT_DEBUG_SQLITE3_PREPARE_V2|DT_DEBUG_SQLITE3_EXEC|sqlite3_prepare_v2|sqlite3_exec)\s*\(')
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')
FUNC_DEF = re.compile(r'^(?!\s)(?:[\w\*\s]+?)\b(\w+)\s*\([^;]*$')
OPS = ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'CREATE', 'DROP', 'ALTER', 'PRAGMA',
       'ATTACH', 'DETACH', 'BEGIN', 'COMMIT', 'ROLLBACK', 'SAVEPOINT', 'RELEASE', 'VACUUM', 'ANALYZE', 'WITH')

# table -> domain of the catalog SDK
DOMAINS = {
  'images': 'images', 'images_new': 'images', 'makers': 'images', 'models': 'images', 'lens': 'images',
  'cameras': 'images', 'exposure_program': 'images', 'metering_mode': 'images', 'whitebalance': 'images',
  'flash': 'images',
  'film_rolls': 'film', 'new_film_rolls': 'film', 'film_folder': 'film',
  'history': 'history', 'masks_history': 'history', 'history_hash': 'history', 'module_order': 'history',
  'snapshot_history': 'history', 'snapshot_masks_history': 'history', 'snapshot_module_order': 'history',
  'tmp_history_hash': 'history',
  'tags': 'tags', 'tagged_images': 'tags', 'used_tags': 'tags', 'darktable_tags': 'tags', 'taglist': 'tags',
  'similar_tags': 'tags',
  'color_labels': 'labels', 'color_labels_temp': 'labels',
  'meta_data': 'metadata',
  'selected_images': 'selection', 'tmp_selection': 'selection', 'tmp_selected_images': 'selection',
  'collected_images': 'collection',
  'styles': 'styles', 'style_items': 'styles',
  'presets': 'presets', 'darktable_iop_names': 'presets',
  'locations': 'locations',
  'overlay': 'overlay', 'overlay_new': 'overlay',
  'harmony_guide': 'images',
  'db_info': 'schema', 'sqlite_master': 'schema', 'sqlite_sequence': 'schema',
}
# unqualified names resolve to the schema that owns the table
DEFAULT_SCHEMA = {'tags': 'data', 'styles': 'data', 'style_items': 'data', 'presets': 'data', 'locations': 'data',
                  'collected_images': 'memory', 'darktable_tags': 'memory', 'taglist': 'memory',
                  'similar_tags': 'memory', 'tmp_selection': 'memory', 'film_folder': 'memory',
                  'darktable_iop_names': 'memory', 'snapshot_history': 'memory',
                  'snapshot_masks_history': 'memory', 'snapshot_module_order': 'memory',
                  'color_labels_temp': 'memory'}
TABLE_RE = re.compile(r'\b(?:(main|data|memory)\.)?(' + '|'.join(sorted(DOMAINS, key=len, reverse=True)) + r')\b')

# where SQL may live once phase 0 step A is done
ALLOWED_PREFIXES = ('common/', 'tests/')

# external interface layers that keep their own SQL on purpose, with why
# (darktable #3841): not step A, not reported by --check
INTERFACE_PREFIXES = {
  'mcp/': 'the MCP bridge takes its sqlite3 handle as a parameter so that '
          'test_mcp_paths.c can run it on an injected minimal database, and '
          'checks that no database reads as "developed" (the --read-only '
          'rollback guarantee); common/ always reads darktable.db',
}

def layer_of(rel):
  if rel == 'common/database.c':
    return 'schema'
  return rel.split('/')[0]

def step_of(rel):
  if rel == 'common/database.c':
    return 'backend'          # schema/migrations: stay in the sqlite backend as is
  if rel.startswith(ALLOWED_PREFIXES):
    return 'B'                # already in common/: move behind the SDK interface
  if rel.startswith(tuple(INTERFACE_PREFIXES)):
    return 'interface'        # kept where it is, see INTERFACE_PREFIXES
  return 'A'                  # GUI/lua/develop/...: move into common/ domain functions

def enclosing_function(lines, idx):
  for j in range(idx, -1, -1):
    m = FUNC_DEF.match(lines[j])
    if m and m.group(1) not in ('if', 'for', 'while', 'switch', 'return', 'sizeof'):
      return m.group(1)
  return '?'

def call_args(text, start):
  depth, i = 0, start
  while i < len(text):
    c = text[i]
    if c == '"':
      i += 1
      while i < len(text) and text[i] != '"':
        i += 2 if text[i] == '\\' else 1
    elif c == '(':
      depth += 1
    elif c == ')':
      depth -= 1
      if depth == 0:
        return text[start + 1:i]
    i += 1
  return text[start + 1:]

def scan(src):
  sites = []
  for root, _, files in os.walk(src):
    for f in files:
      if not f.endswith(('.c', '.cc', '.h', '.cpp')):
        continue
      path = os.path.join(root, f)
      rel = os.path.relpath(path, src)
      if rel.startswith('external/') or rel == 'common/debug.h':
        continue
      text = open(path, encoding='utf-8', errors='replace').read()
      lines = text.split('\n')
      for m in CALLS.finditer(text):
        if text[max(0, m.start() - 8):m.start()].rstrip().endswith('define'):
          continue
        # a call in a line comment is dead code, not a site
        if '//' in text[text.rfind('\n', 0, m.start()) + 1:m.start()]:
          continue
        line = text.count('\n', 0, m.start()) + 1
        args = call_args(text, m.end() - 1)
        sql = ''.join(STRING.findall(args))
        sql_arg = args.split(',', 2)[1] if args.count(',') >= 1 else ''
        dynamic = not sql or not sql_arg.strip().startswith('"')
        if dynamic:
          # SQL built elsewhere (g_strdup_printf, variables): look at the function body around
          lo = max(0, line - 40)
          sql = sql or ''.join(STRING.findall('\n'.join(lines[lo:line])))
        up = sql.upper()
        ops = sorted({op for op in OPS if re.search(r'\b' + op + r'\b', up)})
        tables = sorted({(s or DEFAULT_SCHEMA.get(t, 'main')) + '.' + t for s, t in TABLE_RE.findall(sql)})
        domains = sorted({DOMAINS[t.split('.', 1)[1]] for t in tables})
        writes = bool({'INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'CREATE', 'DROP', 'ALTER'} & set(ops))
        sites.append({
          'file': rel, 'line': line, 'function': enclosing_function(lines, line - 1),
          'call': m.group(1), 'layer': layer_of(rel), 'step': step_of(rel),
          'ops': ops, 'write': writes, 'dynamic': dynamic,
          'tables': tables, 'domains': domains or ['?'],
          'cross_schema': len({t.split('.')[0] for t in tables}) > 1,
          'sql': ' '.join(sql.split())[:400],
        })
  sites.sort(key=lambda s: (s['file'], s['line']))
  return sites

def triggers(src):
  text = open(os.path.join(src, 'common/database.c'), encoding='utf-8').read()
  out = []
  for m in re.finditer(r'CREATE TRIGGER\s+(?:IF NOT EXISTS\s+)?([\w.]+)\s+(\w+\s+\w+(?:\s+OF\s+[\w, ]+)?)\s+ON\s+([\w.]+)', 
                       ''.join(STRING.findall(text)).replace('\\n', ' ')):
    out.append({'name': m.group(1), 'event': ' '.join(m.group(2).split()), 'table': m.group(3)})
  # migrations recreate the same triggers: keep the last definition of each
  return list({t['name']: t for t in out}.values())

def markdown(sites, trig):
  c = Counter
  md = ['# darktable SQL inventory (helios phase 0)', '',
        'Generated by `tools/helios/sql_inventory.py`. Do not edit by hand.', '',
        f'- SQL call sites: **{len(sites)}** in **{len({s["file"] for s in sites})}** files',
        f'- Writes: {sum(s["write"] for s in sites)} - dynamic SQL: {sum(s["dynamic"] for s in sites)}'
        f' - cross-schema: {sum(s["cross_schema"] for s in sites)}',
        f'- Step A (SQL outside common/, to move): **{sum(s["step"] == "A" for s in sites)}**'
        f' - step B (behind the SDK): **{sum(s["step"] == "B" for s in sites)}**'
        f' - schema/migrations: {sum(s["step"] == "backend" for s in sites)}', '']
  md += ['## By domain', '', '| domain | sites | writes | step A | step B | files |', '|---|---|---|---|---|---|']
  by_dom = defaultdict(list)
  for s in sites:
    for d in s['domains']:
      by_dom[d].append(s)
  for d, ss in sorted(by_dom.items(), key=lambda kv: -len(kv[1])):
    md.append(f'| {d} | {len(ss)} | {sum(x["write"] for x in ss)} | {sum(x["step"] == "A" for x in ss)} '
              f'| {sum(x["step"] == "B" for x in ss)} | {len({x["file"] for x in ss})} |')
  md += ['', '## By layer', '', '| layer | sites | files |', '|---|---|---|']
  for l, n in c(s['layer'] for s in sites).most_common():
    md.append(f'| {l} | {n} | {len({s["file"] for s in sites if s["layer"] == l})} |')
  md += ['', '## Tables', '', '| table | sites |', '|---|---|']
  for t, n in c(t for s in sites for t in s['tables']).most_common():
    md.append(f'| `{t}` | {n} |')
  md += ['', f'## Triggers ({len(trig)})', '', '| trigger | event | table |', '|---|---|---|']
  md += [f'| `{t["name"]}` | {t["event"]} | `{t["table"]}` |' for t in trig]
  md += ['', '## Step A sites (outside common/)', '', '| file:line | function | domains | ops |', '|---|---|---|---|']
  md += [f'| `{s["file"]}:{s["line"]}` | `{s["function"]}` | {", ".join(s["domains"])} | {" ".join(s["ops"])} |'
         for s in sites if s['step'] == 'A']
  md += ['', '## Interface layers (SQL kept outside common/ on purpose)', '']
  for prefix, why in INTERFACE_PREFIXES.items():
    md += [f'`{prefix}`: {why}.', '', '| file:line | function | domains | ops |', '|---|---|---|---|']
    md += [f'| `{s["file"]}:{s["line"]}` | `{s["function"]}` | {", ".join(s["domains"])} | {" ".join(s["ops"])} |'
           for s in sites if s['step'] == 'interface' and s['file'].startswith(prefix)]
    md.append('')
  return '\n'.join(md).rstrip('\n') + '\n'

def main():
  ap = argparse.ArgumentParser()
  here = os.path.dirname(os.path.abspath(__file__))
  ap.add_argument('--src', default=os.path.join(here, '..', '..', 'src'))
  ap.add_argument('--json')
  ap.add_argument('--markdown')
  ap.add_argument('--check', action='store_true', help='fail if SQL exists outside allowed paths')
  a = ap.parse_args()
  sites, trig = scan(a.src), triggers(a.src)
  if a.json:
    json.dump({'sites': sites, 'triggers': trig}, open(a.json, 'w'), indent=1, ensure_ascii=False)
  if a.markdown:
    open(a.markdown, 'w').write(markdown(sites, trig))
  if a.check:
    bad = [s for s in sites if s['step'] == 'A']
    for s in bad:
      print(f'{s["file"]}:{s["line"]}: SQL outside common/ in {s["function"]}()', file=sys.stderr)
    sys.exit(1 if bad else 0)
  if not (a.json or a.markdown):
    print(markdown(sites, trig))

if __name__ == '__main__':
  main()
