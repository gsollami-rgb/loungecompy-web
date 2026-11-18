# LoungeCompy — Project Brief per Claude Code

> Questo file è il contesto di progetto. Leggilo per intero prima di scrivere codice.
> Le sezioni marcate **[DA DECIDERE]** sono aperte: non dare per scontata una scelta, chiedi.

---

## 1. Cos'è

App mobile che, dato un aeroporto, mostra le lounge disponibili, le confronta e risponde a due domande:
1. **Posso entrare con quello che ho in tasca?** (carte, conti, membership, status)
2. **Quanto mi costa davvero?**

Il cuore del prodotto è il **motore di accesso**, non la directory. La directory è commodity; l'accesso calcolato su strumenti europei è il differenziatore.

**Perimetro:** Italia + Europa (UE e hub dove volano gli italiani).
**Lingue:** IT, EN, FR, DE, ES (i18n dal giorno zero, nessuna stringa hardcoded).

---

## 2. Posizionamento (perché esiste)

- Competitor: LoungeReview (leader, taglio USA), Loungepedia (solo iOS, solo accesso), This Lounge, AwardWallet, app proprietarie (Priority Pass, DragonPass, Amex). LoungeBuddy chiuso a gennaio 2025.
- Tutti rispondono a "posso entrare?", quasi nessuno a "quale scelgo?".
- Nessuno modella bene gli strumenti europei: HYPE Premium (accesso "incluso" ma ~28-30 € a ingresso), N26 Metal (1 ingresso/anno), Revolut (Ultra illimitato; passaggio DragonPass → LoungeKey), Amex IT, lounge vendute direttamente dall'aeroporto fuori dai network (es. Napoli, Bergamo).
- I dati di LoungeReview **non sono acquistabili** da un progetto individuale: il database va costruito in proprio.

---

## 3. Decisioni prese

| Area | Decisione |
|---|---|
| Nome | LoungeCompy |
| Home | Solo ricerca: GPS propone l'aeroporto (permesso chiesto al primo tap, non all'avvio), campo manuale sempre presente, ultimi 2 aeroporti cercati |
| Scheda aeroporto | Elenco lounge + **filtri** + **ricerca AI in linguaggio naturale** (pattern immobiliare.it: "filtra con l'AI") |
| Accesso | Ogni lounge marcata 🟢 entri gratis / 🟡 entri pagando (prezzo reale accanto) / 🔴 non entri |
| Wallet | Utente registrato: onboarding sul wallet. Ospite: wallet salvato **solo in locale** sul dispositivo, nessun account richiesto. Senza wallet l'accesso diventa un filtro |
| Account | Serve solo per sync tra dispositivi e per contribuire. La registrazione è un premio, non un pedaggio |
| Contributi | Micro-contributo affollamento: 3 bottoni (vuota / normale / piena) + campo opzionale attesa all'ingresso. **Chi contribuisce vede il dato live degli altri** |
| Recensioni lunghe | Non in MVP |
| Stack | Expo universale (iOS, Android, web da un solo codice) + Supabase |
| Font | Montserrat |
| Monetizzazione | Versione con pubblicità (compagnie aeree, prodotti travel) + versione senza pubblicità offerta tramite partner fintech/carte (B2B, a utente attivo o canone). Terzo lato possibile: commissioni dalle lounge per riempire fasce vuote |

---

## 4. Blocchi aperti (in quest'ordine)

### 4.1 Schema dati — BLOCCANTE
Nessuna riga di app o scraper prima che lo schema sia fissato.
Si fissa con un **pilota su 5 scali**: Roma Fiumicino (FCO), Milano Malpensa (MXP), Bergamo (BGY), Napoli (NAP), Francoforte (FRA).

Output del pilota:
- schema definitivo (campi + valori ammessi)
- elenco fonti affidabili / inaffidabili per scalo
- costo reale per scheda (tempo + chiamate LLM)

### 4.2 Stack — DECISO (2026-11-13): Expo universale (iOS/Android/web, Expo Router) + Supabase
Vincolo: la **notifica push il giorno prima del volo** è l'aggancio di retention. Su iOS una PWA ha limiti seri su push e background.
- Proposta di default: **Expo (React Native) + Supabase** (Postgres, auth, storage) — riusa Supabase come CheckWin, risolve le push native.
- Alternativa: PWA (Next.js + Vercel + Supabase) accettando il limite su iOS.

### 4.3 Differenziatore "cosa fare" — da verificare prima di prometterlo
Esempio target: *"Hai 1h47. Dal gate E31 arrivi alla Plaza Premium in 6 minuti, è nella tua area, entri gratis con Revolut Ultra, esci alle 14:05."*
Dipende da due dati **non verificati**:
- **API voli real-time** (terminal, gate, ritardo): costo e copertura UE da verificare.
- **Planimetrie e tempi a piedi**: OpenStreetMap indoor copre solo alcuni scali.

Fallback se non sostenibile: "ti dico terminal, area Schengen/non-Schengen e airside/landside" — comunque meglio dei competitor.

---

## 5. Bozza schema dati (da validare col pilota)

```
airports        iata, icao, name, city, country, lat, lon, timezone
terminals       id, airport_iata, code, name
lounges         id, airport_iata, terminal_id, name, operator,
                area (schengen | non_schengen | mixed),
                side (airside | landside),
                location_note, opening_hours (json), capacity_note,
                photos[], last_verified_at, status (active | closed | temp_closed)
programs        id, type (card | bank_account | network | airline_status | direct),
                name, issuer, network (priority_pass | loungekey | dragonpass | own | none)
access_rules    id, lounge_id, program_id,
                cost_eur (0 = gratis), cost_note,
                guests_allowed, guest_cost_eur,
                conditions (es. "solo voli same-day", "max 3h"),
                valid_from, valid_to, source_id, verified_at
amenities       lounge_id + campi tipizzati:
                food_level, hot_food, sushi, pizza_snacks,
                bar_cocktails, draft_beer, wine, coffee_quality,
                showers, sleep_pods, quiet_zone, work_desks,
                power_per_seat, wifi_quality, kids_area, view_runway
occupancy_reports  id, lounge_id, user_id, level (empty | normal | full),
                   queue_minutes, created_at
sources         id, type (airport_site | operator_site | network | review | photo | blog),
                url, fetched_at
```

Principio: ogni dato di accesso e prezzo ha **fonte e data di verifica**. Un prezzo sbagliato in aeroporto brucia la fiducia.

---

## 6. Pipeline dati

Due stadi distinti:

1. **Struttura** — siti aeroporti, operatori (Plaza Premium, Aspire/Swissport, Menzies, ADR, SEA, Aena), network (Priority Pass, LoungeKey, DragonPass): esistenza, terminal, area, orari, prezzi, regole di accesso.
2. **Dettaglio** — foto e recensioni (Google Maps, TripAdvisor, blog, YouTube) passate a un modello di visione/LLM che estrae i campi `amenities`. I siti degli aeroporti non dicono se la birra è alla spina.

Vincoli:
- rispettare robots.txt e termini di servizio, rate limiting
- 24 lingue sorgente, strutture tutte diverse
- lo scraper di massa gira su server dedicato, non in locale
- manutenzione: il crawler rileva **diff** e un umano verifica solo quelli

Stime (assunzioni, non verificate): 600-900 lounge in 120-200 aeroporti europei; build iniziale ~6k € + sviluppo pipeline; manutenzione ~8-10k €/anno.

---

## 7. Roadmap

| Fase | Contenuto | Uscita |
|---|---|---|
| 0 | Pilota 5 scali + verifica API voli e planimetrie | Schema definitivo, costi reali, go/no-go sul "cosa fare" |
| 1 | Decisione stack, setup repo, i18n, design system | Scheletro app |
| 2 | MVP: ricerca aeroporto, scheda aeroporto, lista lounge, filtri, wallet locale, 🟢🟡🔴 | App usabile sui 5 scali |
| 3 | Ricerca AI, account, micro-contributo affollamento | Beta |
| 4 | Espansione dati UE, numero di volo + notifica, monetizzazione | Lancio |

---

## 8. Brand

- **Colori:** blu notte `#0B2545` (base), ambra `#F0A202` (accento: solo timone dell'aereo e highlight).
- **Simbolo:** L con cappio alla base (asta ~70%) + C a forma di jet in virata (ali asimmetriche, timone ambra, finestrino di cabina). Asset SVG/PNG già prodotti → copiarli in `assets/brand/`.
- **Font:** Montserrat (deciso 2026-11-13, via @expo-google-fonts/montserrat). Lettering "LoungeCompy" completo ancora da fare.
- **Animazione splash:** la L si disegna (stroke-dashoffset, tracciato unico), l'aereo percorre la curva e forma la C, poi decolla verso destra; la L si contrae nell'icona in alto a sinistra e al centro resta la barra di ricerca.

---

## 9. Regole per Claude Code

- Non inventare dati di lounge, prezzi o regole d'accesso. Se un dato manca, campo `null` + fonte mancante.
- Ogni prezzo mostrato in UI deve avere `verified_at` visibile o accessibile.
- Tutte le stringhe UI passano per i18n (5 lingue).
- Wallet ospite: mai inviato al server.
- Prima di scegliere librerie o servizi a pagamento, chiedi.
- Lavora per fasi: non anticipare la fase 2 finché la fase 0 non ha prodotto lo schema.


---

## 10. Stato al 18/11/2026 (sito web pubblico)

Il prototipo web è online su **https://lounge-compy.com** (repo `nleone-p4b/loungecompy-web`, GitHub Pages, HTTPS). L'app nativa Expo resta la fase successiva.

**Decisioni prese in corso d'opera**
- **Backend:** Supabase, progetto `yavlmzltdosimuzfksak` (org The Crowd, Francoforte). Migrazioni in `db/*.sql` nel repo web, eseguite in ordine.
- **Login:** email + codice a 6 cifre via Resend (mittente `accesso@lounge-compy.com`). Niente password. Google login da fare (credenziali OAuth); Apple con l'app iOS.
- **Wallet:** ospite solo locale; utente registrato sincronizzato con l'account (solo nomi di prodotto). Programmi con **quota** (Amex Oro 2/anno, N26 Metal 1/anno…) e contatore ingressi dell'anno, alimentato anche dai check-in verificati.
- **Check-in** solo entro 6 km dall'aeroporto (posizione letta, non salvata); gli admin possono fare check-in di prova.
- **Voti** 1–5 con aerei, commento ≤280 caratteri, solo dopo check-in. Foto moderate dal pannello.
- **Ruoli:** `profiles.role` (user/admin); pannello su `/admin`; inviti admin per email; registro `admin_log`.
- **Dati lounge:** il repo è la fonte (task settimanale); Supabase riceve gli aggiornamenti con "Importa dati aggiornati" dal pannello; le modifiche fatte a mano dal pannello vincono finché il JSON non è più recente.
- **SEO:** `build_pages.py` genera `l/<id>.html`, `a/<iata>.html`, sitemap.
- **Notifiche:** Il mio volo + web push (sw.js, chiave VAPID in `supabase/README.md`); l'edge function `flight-reminders` va deployata con i secrets.
- **Titolare privacy:** Nicola Leone, leonenicola10@gmail.com.
