#!/usr/bin/env python3
"""Genera le pagine statiche indicizzabili: l/<id>.html (una per lounge), a/<iata>.html (una per aeroporto),
sitemap.xml e robots.txt. Legge data/lounges.json e data/airports.json. Idempotente: si rilancia dopo ogni aggiornamento dati."""
import json, os, html, re, datetime
ROOT = os.path.dirname(os.path.abspath(__file__))
L = json.load(open(os.path.join(ROOT, 'data/lounges.json'), encoding='utf-8'))
A = json.load(open(os.path.join(ROOT, 'data/airports.json'), encoding='utf-8'))
META = json.load(open(os.path.join(ROOT, 'data/meta.json'), encoding='utf-8'))
SITE = 'https://lounge-compy.com'
NET = {'pp': 'Priority Pass', 'lk': 'LoungeKey', 'dp': 'DragonPass', 'amex': 'Amex Platino', 'diners': 'Diners Club'}
AREA = {'schengen': 'Schengen', 'extra': 'extra-Schengen', 'both': 'Schengen ed extra-Schengen', 'na': 'airside'}
e = lambda x: html.escape(str(x or ''))
def fd(d): return '/'.join(reversed((d or '').split('-'))) if d else ''

HEAD = '''<!DOCTYPE html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>{title}</title><meta name="description" content="{desc}"><link rel="canonical" href="{url}">
<meta property="og:title" content="{title}"><meta property="og:description" content="{desc}"><meta property="og:url" content="{url}"><meta property="og:type" content="website"><meta property="og:image" content="{site}/icons/icon-512.png">
<link rel="icon" type="image/png" sizes="32x32" href="/icons/icon-32.png"><link rel="apple-touch-icon" href="/icons/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Jost:ital,wght@0,200;0,300;0,400;0,500;1,300&display=swap" rel="stylesheet">
<style>:root{{--navy:#0B2545;--gold:#A8812E;--muted:#6B7280;--line:#E6E9EE;--free:#2E8B57;--pay:#B8860B;--no:#B23A48}}*{{box-sizing:border-box;margin:0;padding:0}}body{{font-family:'Jost',system-ui,sans-serif;font-weight:300;color:var(--navy);background:#fff;-webkit-font-smoothing:antialiased;line-height:1.5}}
.wrap{{max-width:720px;margin:0 auto;padding:24px 20px 60px}}.wm{{font-size:22px;font-weight:400}}.wm i{{font-style:italic;font-weight:300;color:var(--gold)}}.wm a{{color:inherit;text-decoration:none}}
.crumb{{font-size:13px;color:var(--muted);margin-top:18px}}.crumb a{{color:var(--muted)}}h1{{font-size:30px;font-weight:200;line-height:1.15;margin:8px 0 4px}}.sub{{color:var(--muted);font-size:15px}}
h2{{font-size:12px;letter-spacing:.22em;text-transform:uppercase;color:var(--muted);font-weight:400;margin:30px 0 8px}}table{{border-collapse:collapse;width:100%;font-size:15px}}td{{padding:9px 6px;border-bottom:1px solid var(--line);vertical-align:top}}td:first-child{{color:var(--muted);width:36%}}
.cta{{display:block;margin:26px 0;border:1px solid var(--navy);border-radius:16px;padding:14px 16px;text-decoration:none;color:var(--navy)}}.cta b{{font-weight:500;display:block;margin-bottom:4px}}.cta span{{font-size:13px;color:var(--muted)}}
.ok{{color:var(--free)}}.no{{color:var(--no)}}.unk{{color:var(--muted)}}.src{{font-size:12.5px;color:var(--muted);margin-top:24px;line-height:1.5}}.list a{{display:block;padding:12px 0;border-bottom:1px solid var(--line);text-decoration:none;color:inherit}}.list a b{{font-weight:400;display:block}}.list a span{{font-size:13px;color:var(--muted)}}
.foot{{margin-top:40px;font-size:12px;color:#A9B0BC}}.foot a{{color:var(--muted)}}</style>
<script type="application/ld+json">{ld}</script></head><body><div class="wrap"><div class="wm"><a href="/">Lounge<i>Compy</i></a></div>'''
FOOT = '''<div class="foot">Dati aggiornati al {upd}. I prezzi e le regole di accesso cambiano spesso: verifica sempre con la lounge. · <a href="/privacy.html">Privacy</a> · <a href="/termini.html">Termini</a></div></div></body></html>'''

def acc_cls(v):
    v = v or ''
    if v.startswith('Sì') or v == 'Via Priority Pass': return 'ok'
    if v in ('No', 'Sospeso'): return 'no'
    return 'unk'

os.makedirs(os.path.join(ROOT, 'l'), exist_ok=True); os.makedirs(os.path.join(ROOT, 'a'), exist_ok=True)
urls = []
apmap = {a['iata']: a for a in A}
for l in L:
    a = apmap.get(l['ap'], {}); url = f"{SITE}/l/{l['id']}.html"; urls.append((url, l.get('checked') or META.get('updated')))
    nets = [NET[k] for k, v in (l.get('acc') or {}).items() if (v or '').startswith('Sì') or v == 'Via Priority Pass']
    price = l.get('price') or 'n.d.'
    desc = f"{l['name']} all'aeroporto di {a.get('city','')} ({l['ap']}): {l.get('ta','')}. Accesso con {', '.join(nets) if nets else 'biglietto a pagamento'}. Prezzo: {price}. Orari {l.get('hours','n.d.')}. Dati verificati il {fd(l.get('checked'))}."[:300]
    title = f"{l['name']} · {a.get('city','')} {l['ap']} — prezzi, orari e come entrare | LoungeCompy"
    ld = json.dumps({"@context": "https://schema.org", "@type": "LocalBusiness", "name": l['name'], "url": url, "address": {"@type": "PostalAddress", "addressLocality": a.get('city', ''), "addressCountry": a.get('country', '')}, "openingHours": l.get('hours', ''), "priceRange": price, "isAccessibleForFree": False, "containedInPlace": {"@type": "Airport", "name": a.get('name', ''), "iataCode": l['ap']}}, ensure_ascii=False)
    rows = ''.join(f"<tr><td>{e(NET[k])}</td><td class='{acc_cls(v)}'>{e(v or 'n.d.')}</td></tr>" for k, v in (l.get('acc') or {}).items())
    svc = ''.join(f"<tr><td>{e(k)}</td><td>{e(v)}</td></tr>" for k, v in [('Cibo', l.get('food')), ('Bar', l.get('bar')), ('Birra alla spina', l.get('beer')), ('Docce', l.get('shower')), ('Altro', l.get('other'))] if v and v != 'n.d.')
    body = f'''<div class="crumb"><a href="/">Aeroporti</a> › <a href="/a/{l['ap']}.html">{e(a.get('city',''))} {l['ap']}</a></div>
<h1>{e(l['name'])}</h1><div class="sub">{e(l.get('ta',''))}{' · chiusa' if re.search('chius', l.get('status') or '', re.I) else ''}</div>
<a class="cta" href="/#l={l['id']}"><b>Entri gratis con le tue carte?</b><span>Apri LoungeCompy: aggiungi carte e conti nel wallet e lo calcoliamo per te. Check-in, voti e affollamento in tempo reale.</span></a>
<h2>Dove e quando</h2><table><tr><td>Posizione</td><td>{e(l.get('pos',''))}</td></tr><tr><td>Area</td><td>{e(AREA.get(l.get('area'),'')) or 'n.d.'}</td></tr><tr><td>Orari</td><td>{e(l.get('hours','n.d.'))}</td></tr><tr><td>Permanenza massima</td><td>{e(l.get('stay','n.d.'))}</td></tr></table>
<h2>Come si entra</h2><table>{rows}<tr><td>Ingresso a pagamento</td><td>{'Non in vendita' if price=='No' else e(price)}</td></tr></table>
{('<h2>Servizi</h2><table>'+svc+'</table>') if svc else ''}
{('<h2>Note</h2><p>'+e(l.get('note'))+'</p>') if l.get('note') else ''}
<div class="src"><b>Fonti</b> · ultimo controllo {fd(l.get('checked'))}<br>Orari e accessi: {e(l.get('srcA',''))}<br>Prezzo: {e(l.get('srcP',''))}<br>Servizi: {e(l.get('srcS',''))}</div>'''
    open(os.path.join(ROOT, 'l', l['id'] + '.html'), 'w', encoding='utf-8').write(HEAD.format(title=e(title), desc=e(desc), url=url, site=SITE, ld=ld) + body + FOOT.format(upd=fd(META.get('updated'))))

for a in A:
    ls = [l for l in L if l['ap'] == a['iata']]; url = f"{SITE}/a/{a['iata']}.html"; urls.append((url, META.get('updated')))
    title = f"Lounge aeroporto {a['city']} {a['iata']}: {len(ls)} sale VIP, prezzi e accesso | LoungeCompy"
    desc = f"Tutte le lounge di {a['name']} ({a['iata']}): {', '.join(l['name'] for l in ls)[:200]}. Prezzi, orari, Priority Pass, LoungeKey, DragonPass, Amex. Dati aggiornati al {fd(META.get('updated'))}."[:300]
    ld = json.dumps({"@context": "https://schema.org", "@type": "Airport", "name": a['name'], "iataCode": a['iata'], "url": url, "address": {"@type": "PostalAddress", "addressLocality": a['city'], "addressCountry": a.get('country', '')}}, ensure_ascii=False)
    items = ''.join(f"<a href='/l/{l['id']}.html'><b>{e(l['name'])}</b><span>{e(l.get('ta',''))} · {('Non in vendita' if (l.get('price') or '')=='No' else e(l.get('price') or 'prezzo n.d.'))}</span></a>" for l in ls)
    body = f'''<div class="crumb"><a href="/">Aeroporti</a></div><h1>Lounge a {e(a['city'])} · {a['iata']}</h1><div class="sub">{e(a['name'])} · {len(ls)} lounge</div>
<a class="cta" href="/#a={a['iata']}"><b>Quale lounge scegliere?</b><span>In LoungeCompy filtri per quello che ti serve (cibo, docce, silenzio) e vedi dove entri gratis con le tue carte.</span></a>
<h2>Le lounge</h2><div class="list">{items}</div>'''
    open(os.path.join(ROOT, 'a', a['iata'] + '.html'), 'w', encoding='utf-8').write(HEAD.format(title=e(title), desc=e(desc), url=url, site=SITE, ld=ld) + body + FOOT.format(upd=fd(META.get('updated'))))

today = datetime.date.today().isoformat()
sm = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + f'<url><loc>{SITE}/</loc><lastmod>{META.get("updated", today)}</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>\n' + ''.join(f'<url><loc>{u}</loc><lastmod>{d or today}</lastmod><changefreq>weekly</changefreq></url>\n' for u, d in urls) + '</urlset>\n'
open(os.path.join(ROOT, 'sitemap.xml'), 'w').write(sm)
open(os.path.join(ROOT, 'robots.txt'), 'w').write(f"User-agent: *\nAllow: /\nDisallow: /admin/\nSitemap: {SITE}/sitemap.xml\n")
print(f"{len(L)} lounge, {len(A)} aeroporti, sitemap con {len(urls)+1} URL")
