-- LoungeCompy · step 4: quote wallet, modifica lounge da admin, import, eventi/statistiche, voli+push, elimina account

-- ========== WALLET: ingressi già usati (contatore manuale per programma) ==========
alter table public.user_wallet add column if not exists used jsonb not null default '{}'::jsonb;

-- check-in verificati dell'anno in corso, per circuito accettato dalla lounge (per le quote: Amex Oro 2/anno, N26 Metal 1/anno…)
create or replace function public.my_year_visits()
returns table (net text, n bigint) language sql stable security definer set search_path = public as $$
  select k.net, count(distinct c.id)
  from checkins c join lounges l on l.id = c.lounge_id
  cross join lateral (values ('pp'),('lk'),('dp'),('amex'),('diners')) as k(net)
  where c.user_id = auth.uid() and c.geo_verified
    and c.created_at >= date_trunc('year', now())
    and coalesce(l.acc->>k.net,'') like 'Sì%'
  group by k.net;
$$;
revoke all on function public.my_year_visits() from anon; grant execute on function public.my_year_visits() to authenticated;

-- ========== LOUNGE: modifica da pannello admin + import dal JSON del sito ==========
alter table public.lounges add column if not exists admin_edited_at timestamptz, add column if not exists admin_edited_by uuid;
drop policy if exists "admin modifica lounge" on public.lounges;
create policy "admin modifica lounge" on public.lounges for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin modifica aeroporti" on public.airports;
create policy "admin modifica aeroporti" on public.airports for update using (public.is_admin()) with check (public.is_admin());

create or replace function public.admin_update_lounge(p_id text, p_patch jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  update lounges set
    name = coalesce(p_patch->>'name', name), ta = coalesce(p_patch->>'ta', ta), hours = coalesce(p_patch->>'hours', hours),
    price = coalesce(p_patch->>'price', price), stay = coalesce(p_patch->>'stay', stay), pos = coalesce(p_patch->>'pos', pos),
    note = coalesce(p_patch->>'note', note), status = coalesce(p_patch->>'status', status),
    acc = coalesce(p_patch->'acc', acc),
    src_a = coalesce(p_patch->>'src_a', src_a), src_p = coalesce(p_patch->>'src_p', src_p), src_s = coalesce(p_patch->>'src_s', src_s),
    checked = current_date, admin_edited_at = now(), admin_edited_by = auth.uid(), updated_at = now()
  where id = p_id;
  insert into admin_log (admin_id, action, target_type, target_ref, note) values (auth.uid(), 'lounge_edit', 'lounge', p_id, left(p_patch::text, 500));
  return found;
end $$;
revoke all on function public.admin_update_lounge(text, jsonb) from anon, public; grant execute on function public.admin_update_lounge(text, jsonb) to authenticated;

-- import dal JSON pubblicato dal task settimanale: vince il più recente (non sovrascrive modifiche admin più nuove del "checked")
create or replace function public.admin_import_lounges(p_rows jsonb, p_airports jsonb default '[]'::jsonb)
returns table (inserted int, updated int, skipped int) language plpgsql security definer set search_path = public as $$
declare r jsonb; a jsonb; v_ins int := 0; v_upd int := 0; v_skip int := 0; v_checked date; v_adm timestamptz; v_exists boolean;
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  for a in select * from jsonb_array_elements(p_airports) loop
    insert into airports (iata, city, name, country, departures, departures_checked, lat, lon)
    values (a->>'iata', a->>'city', a->>'name', a->>'country', a->>'departures', nullif(a->>'departures_checked','')::date, (a->>'lat')::double precision, (a->>'lon')::double precision)
    on conflict (iata) do update set city = excluded.city, name = excluded.name, country = excluded.country, departures = excluded.departures,
      departures_checked = excluded.departures_checked, lat = coalesce(excluded.lat, airports.lat), lon = coalesce(excluded.lon, airports.lon), updated_at = now();
  end loop;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_checked := nullif(r->>'checked','')::date;
    select true, admin_edited_at into v_exists, v_adm from lounges where id = r->>'id';
    if v_exists and v_adm is not null and (v_checked is null or v_checked <= v_adm::date) then v_skip := v_skip + 1; continue; end if;
    insert into lounges (id, airport_iata, name, ta, area, side, pos, hours, acc, price, stay, food, bar, beer, shower, other, note, src_a, src_p, src_s, checked, aliases, operator, status, contacts)
    values (r->>'id', r->>'ap', r->>'name', r->>'ta', nullif(r->>'area',''), r->>'side', r->>'pos', r->>'hours', coalesce(r->'acc','{}'::jsonb), r->>'price', r->>'stay',
      r->>'food', r->>'bar', r->>'beer', r->>'shower', r->>'other', r->>'note', r->>'srcA', r->>'srcP', r->>'srcS', v_checked,
      coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(r->'aliases')='array' then r->'aliases' else '[]'::jsonb end)), '{}'), r->>'operator', r->>'status', r->'contacts')
    on conflict (id) do update set airport_iata = excluded.airport_iata, name = excluded.name, ta = excluded.ta, area = excluded.area, side = excluded.side, pos = excluded.pos,
      hours = excluded.hours, acc = excluded.acc, price = excluded.price, stay = excluded.stay, food = excluded.food, bar = excluded.bar, beer = excluded.beer, shower = excluded.shower,
      other = excluded.other, note = excluded.note, src_a = excluded.src_a, src_p = excluded.src_p, src_s = excluded.src_s, checked = excluded.checked, aliases = excluded.aliases,
      operator = excluded.operator, status = excluded.status, contacts = excluded.contacts, admin_edited_at = null, updated_at = now();
    if v_exists then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
  end loop;
  insert into admin_log (admin_id, action, target_type, target_ref, note) values (auth.uid(), 'lounge_import', 'lounge', 'bulk', format('ins %s upd %s skip %s', v_ins, v_upd, v_skip));
  return query select v_ins, v_upd, v_skip;
end $$;
revoke all on function public.admin_import_lounges(jsonb, jsonb) from anon, public; grant execute on function public.admin_import_lounges(jsonb, jsonb) to authenticated;

-- ========== EVENTI (statistiche d'uso, senza cookie) ==========
create table if not exists public.events (
  id bigint generated always as identity primary key,
  type text not null check (type in ('search','search_empty','view','ai','share','install')),
  ref text, user_id uuid, lang text,
  created_at timestamptz not null default now()
);
create index if not exists events_time_idx on public.events(created_at desc);
alter table public.events enable row level security;
drop policy if exists "tutti registrano eventi" on public.events;
create policy "tutti registrano eventi" on public.events for insert with check (char_length(coalesce(ref,'')) <= 120 and (user_id is null or user_id = auth.uid()));
drop policy if exists "admin legge eventi" on public.events;
create policy "admin legge eventi" on public.events for select using (public.is_admin());

create or replace function public.admin_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_admin() then jsonb_build_object(
    'active_7d', (select count(distinct user_id) from (select user_id from checkins where created_at > now()-interval '7 days' union select user_id from ratings where updated_at > now()-interval '7 days' union select user_id from events where user_id is not null and created_at > now()-interval '7 days') x),
    'visitors_7d', (select count(*) from events where type in ('view','search') and created_at > now()-interval '7 days'),
    'checkins_by_day', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]'::jsonb) from (select date_trunc('day', created_at)::date d, count(*) n from checkins where created_at > now()-interval '14 days' group by 1) q),
    'top_views', (select coalesce(jsonb_agg(jsonb_build_object('id', ref, 'name', l.name, 'ap', l.airport_iata, 'n', n) order by n desc), '[]'::jsonb) from (select ref, count(*) n from events where type='view' and created_at > now()-interval '30 days' group by ref order by n desc limit 10) q join lounges l on l.id = q.ref),
    'top_searches', (select coalesce(jsonb_agg(jsonb_build_object('q', ref, 'n', n) order by n desc), '[]'::jsonb) from (select lower(ref) ref, count(*) n from events where type='search' and created_at > now()-interval '30 days' group by 1 order by n desc limit 15) q),
    'empty_searches', (select coalesce(jsonb_agg(jsonb_build_object('q', ref, 'n', n) order by n desc), '[]'::jsonb) from (select lower(ref) ref, count(*) n from events where type='search_empty' and created_at > now()-interval '30 days' group by 1 order by n desc limit 15) q),
    'installs', (select count(*) from events where type='install'),
    'shares_30d', (select count(*) from events where type='share' and created_at > now()-interval '30 days')
  ) else null end;
$$;
revoke all on function public.admin_stats() from anon, public; grant execute on function public.admin_stats() to authenticated;

-- ========== IL MIO VOLO + NOTIFICHE PUSH ==========
create table if not exists public.flights (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  airport_iata text not null references public.airports(iata),
  flight_no text check (char_length(flight_no) <= 10),
  dep_at timestamptz not null,
  lounge_id text references public.lounges(id) on delete set null,
  notify_at timestamptz,              -- quando mandare la notifica (di norma dep_at - 1 giorno, ore 9 locali)
  notified_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists flights_notify_idx on public.flights(notify_at) where notified_at is null;
alter table public.flights enable row level security;
drop policy if exists "i miei voli" on public.flights;
create policy "i miei voli" on public.flights for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  p256dh text not null, auth text not null, ua text,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "le mie iscrizioni push" on public.push_subscriptions;
create policy "le mie iscrizioni push" on public.push_subscriptions for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ========== ELIMINA ACCOUNT (GDPR, self-service) ==========
create or replace function public.delete_my_account() returns void language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();   -- cascata su profiles, favorites, checkins, ratings, photos, wallet, flights
end $$;
revoke all on function public.delete_my_account() from anon, public; grant execute on function public.delete_my_account() to authenticated;
