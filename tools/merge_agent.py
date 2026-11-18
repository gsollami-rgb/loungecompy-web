"""Fonde l'output dell'agente di ricerca (un JSON per aeroporto) nel database di LoungeCompy.
Uso: python3 merge_agent.py <lounges.json> <meta.json> <mapping.json>
mapping.json: {"<file agente>": {"<nome nell'output agente>": "<id esistente o nuovo>", ...}, ...}
più facoltativi "price_override" {id: testo}, "name_override" {id: nome}, "note_prefix" {id: testo}, "changelog" [testi].
Regole: mai sovrascrivere schede con fonte '(conferma operatore)'; un 'Da verificare' dell'agente
non cancella un valore già presente; il prezzo usa '€N' come primo importo (lo legge l'app)."""
import json, sys, re
from urllib.parse import urlparse
Lp, Mp, mapp = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
L = json.load(open(Lp)); M = json.load(open(Mp)); byid = {l['id']: l for l in L}
ACC_F = ('acc', 'hours', 'pos', 'ta', 'status', 'stay', 'area', 'side', 'note')
SRV_F = ('food', 'bar', 'beer', 'shower', 'other')
def dt(s): y, m, d = s.split('-'); return f'{d}/{m}/{y}'
def srcline(s):
    dom = urlparse(s['url'].split(' ')[0]).netloc.replace('www.', '')
    tag = {'network': '', 'airport_site': '', 'operator_site': '', 'reseller': ' (rivenditore)', 'review': ' (fonte secondaria)'}.get(s.get('type'), '')
    return f"{dom}{tag} – letto {dt(s['read_at'])}"
def srcs(rec, keys):
    out = []
    for s in rec.get('sources', []):
        f = s['field'].lower()
        if any(k in f for k in keys):
            line = srcline(s)
            if line not in out: out.append(line)
    return '\n'.join(out)
def v(x): return 'n.d.' if x in (None, '') else x
added, updated = [], []
for fname, names in mapp['files'].items():
    data = json.load(open(fname))
    for rec in data['lounges']:
        lid = names.get(rec['name'])
        if not lid: continue
        old = byid.get(lid)
        if old and any('(conferma operatore)' in (old.get(k) or '') for k in ('srcA', 'srcP', 'srcS')):
            print('SKIP conferma operatore:', lid); continue
        acc = dict(old['acc']) if old else {}
        for k, val in rec['acc'].items():
            if val == 'Da verificare' and acc.get(k) and acc[k] != 'Da verificare': continue
            acc[k] = val
        new = {
            'id': lid, 'ap': rec['ap'], 'name': mapp.get('name_override', {}).get(lid, rec['name']),
            'ta': v(rec.get('ta')), 'area': rec.get('area') or 'na', 'side': rec.get('side') or 'airside',
            'pos': v(rec.get('pos')), 'hours': v(rec.get('hours')), 'acc': acc,
            'price': mapp.get('price_override', {}).get(lid) or v(rec.get('price')),
            'stay': v(rec.get('stay')), 'food': v(rec.get('food')), 'bar': v(rec.get('bar')),
            'beer': v(rec.get('beer')), 'shower': v(rec.get('shower')), 'other': v(rec.get('other')),
            'note': (mapp.get('note_prefix', {}).get(lid, '') + (rec.get('note') or '')).strip(),
            'srcA': srcs(rec, ('acc', 'hours', 'pos', 'ta', 'status', 'stay', 'side', 'area')) or (old or {}).get('srcA', ''),
            'srcP': srcs(rec, ('price',)) or (old or {}).get('srcP', ''),
            'srcS': srcs(rec, ('food', 'bar', 'beer', 'shower', 'other')) or (old or {}).get('srcS', ''),
            'checked': rec.get('checked'),
            'aliases': rec.get('aliases', []), 'operator': rec.get('operator'), 'status': rec.get('status'),
            'contacts': rec.get('contacts'),
        }
        if new['price'] == 'n.d.' and old: new['price'] = old['price']
        new['acc'].update(mapp.get('acc_override', {}).get(lid, {}))
        if old:
            old.clear(); old.update(new); updated.append(lid)
        else:
            # inserisci dopo l'ultima lounge dello stesso aeroporto
            idx = max(i for i, l in enumerate(L) if l['ap'] == rec['ap']) + 1
            L.insert(idx, new); byid[lid] = new; added.append(lid)
drop = set(mapp.get('drop', []))
L[:] = [l for l in L if l['id'] not in drop]
if drop: print('rimosse', sorted(drop))
json.dump(L, open(Lp, 'w'), ensure_ascii=False, indent=1)
day = max(r for r in [l.get('checked') or '' for l in L])
M['updated'] = day
for t in mapp.get('changelog', []): M['changelog'].append({'date': day, 'text': t})
json.dump(M, open(Mp, 'w'), ensure_ascii=False, indent=1)
print('aggiornate', updated); print('aggiunte', added); print('totale', len(L))
