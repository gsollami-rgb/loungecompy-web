-- LoungeCompy · schema v1 (step 1: dati lounge, profili, preferiti, check-in, voti)
-- Nota: le tabelle airports/lounges ricalcano il formato attuale del prototipo (lounges.json).
-- Lo schema definitivo dei dati di accesso esce dal pilota (fase 0): qui niente normalizzazione prematura.

-- ========== DATI PUBBLICI ==========
create table if not exists public.airports (
  iata text primary key check (iata ~ '^[A-Z]{3}$'),
  city text not null,
  name text not null,
  country text not null,
  departures text,
  departures_checked date,
  updated_at timestamptz not null default now()
);

create table if not exists public.lounges (
  id text primary key,
  airport_iata text not null references public.airports(iata),
  name text not null,
  ta text,
  area text check (area in ('schengen','extra','both','na')),
  side text,
  pos text,
  hours text,
  acc jsonb not null default '{}'::jsonb,   -- {pp,lk,dp,amex,diners}
  price text,
  stay text,
  food text, bar text, beer text, shower text, other text, note text,
  src_a text, src_p text, src_s text,        -- fonti accesso / prezzo / servizi
  checked date,                              -- verified_at
  aliases text[] not null default '{}',
  operator text,
  status text,
  contacts jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists lounges_airport_idx on public.lounges(airport_iata);

alter table public.airports enable row level security;
alter table public.lounges  enable row level security;
drop policy if exists "airports leggibili da tutti" on public.airports;
create policy "airports leggibili da tutti" on public.airports for select using (true);
drop policy if exists "lounges leggibili da tutti" on public.lounges;
create policy "lounges leggibili da tutti" on public.lounges for select using (true);
-- scritture solo da service role / SQL editor (nessuna policy insert/update)

-- ========== PROFILI ==========
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) <= 40),
  avatar_url text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profili leggibili" on public.profiles;
create policy "profili leggibili" on public.profiles for select using (true);
drop policy if exists "aggiorno il mio profilo" on public.profiles;
create policy "aggiorno il mio profilo" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (new.id,
          left(coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)), 40),
          new.raw_user_meta_data->>'avatar_url')
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ========== PREFERITI ==========
create table if not exists public.favorites (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  lounge_id text not null references public.lounges(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, lounge_id)
);
alter table public.favorites enable row level security;
drop policy if exists "i miei preferiti" on public.favorites;
create policy "i miei preferiti" on public.favorites for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ========== CHECK-IN + AFFOLLAMENTO ==========
create table if not exists public.checkins (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  lounge_id text not null references public.lounges(id) on delete cascade,
  occupancy text check (occupancy in ('empty','normal','full')),
  queue_minutes smallint check (queue_minutes between 0 and 180),
  geo_verified boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists checkins_lounge_time_idx on public.checkins(lounge_id, created_at desc);
create index if not exists checkins_user_idx on public.checkins(user_id, created_at desc);
alter table public.checkins enable row level security;
drop policy if exists "vedo i miei check-in" on public.checkins;
create policy "vedo i miei check-in" on public.checkins for select using (auth.uid() = user_id);
drop policy if exists "faccio check-in" on public.checkins;
create policy "faccio check-in" on public.checkins for insert with check (
  auth.uid() = user_id
  -- max 1 check-in per lounge ogni 2 ore
  and not exists (select 1 from public.checkins c where c.user_id = auth.uid()
                  and c.lounge_id = checkins.lounge_id and c.created_at > now() - interval '2 hours')
);

-- ========== VOTI + COMMENTO BREVE ==========
create table if not exists public.ratings (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  lounge_id text not null references public.lounges(id) on delete cascade,
  stars smallint not null check (stars between 1 and 5),
  comment text check (char_length(comment) <= 280),
  hidden boolean not null default false,        -- moderazione
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, lounge_id)
);
alter table public.ratings enable row level security;
drop policy if exists "voti visibili" on public.ratings;
create policy "voti visibili" on public.ratings for select using (not hidden or auth.uid() = user_id);
drop policy if exists "voto solo dopo check-in" on public.ratings;
create policy "voto solo dopo check-in" on public.ratings for insert with check (
  auth.uid() = user_id and hidden = false
  and exists (select 1 from public.checkins c where c.user_id = auth.uid() and c.lounge_id = ratings.lounge_id)
);
drop policy if exists "modifico il mio voto" on public.ratings;
create policy "modifico il mio voto" on public.ratings for update
  using (auth.uid() = user_id) with check (auth.uid() = user_id and hidden = false);
drop policy if exists "cancello il mio voto" on public.ratings;
create policy "cancello il mio voto" on public.ratings for delete using (auth.uid() = user_id);

-- ========== SEGNALAZIONI ==========
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  target_type text not null check (target_type in ('rating','photo','lounge_data')),
  target_ref text not null,
  reason text check (char_length(reason) <= 500),
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;
drop policy if exists "invio segnalazioni" on public.reports;
create policy "invio segnalazioni" on public.reports for insert with check (auth.uid() = user_id);

-- ========== FUNZIONI AGGREGATE (lette dal sito) ==========
-- Statistiche pubbliche per lounge: visite 30gg, totali, preferiti, media voti
create or replace function public.lounge_stats(p_airport text default null)
returns table (lounge_id text, visits_30d bigint, visits_total bigint, favorites bigint, avg_stars numeric, n_ratings bigint)
language sql stable security definer set search_path = public as $$
  select l.id,
    (select count(*) from checkins c where c.lounge_id = l.id and c.created_at > now() - interval '30 days'),
    (select count(*) from checkins c where c.lounge_id = l.id),
    (select count(*) from favorites f where f.lounge_id = l.id),
    (select round(avg(r.stars)::numeric, 1) from ratings r where r.lounge_id = l.id and not r.hidden),
    (select count(*) from ratings r where r.lounge_id = l.id and not r.hidden)
  from lounges l
  where p_airport is null or l.airport_iata = p_airport;
$$;

-- Classifica live: più visitate (30gg) o più preferite
create or replace function public.lounge_ranking(p_by text default 'visits', p_limit int default 20)
returns table (lounge_id text, name text, airport_iata text, score bigint)
language sql stable security definer set search_path = public as $$
  select l.id, l.name, l.airport_iata,
    case when p_by = 'favorites'
      then (select count(*) from favorites f where f.lounge_id = l.id)
      else (select count(*) from checkins c where c.lounge_id = l.id and c.created_at > now() - interval '30 days')
    end as score
  from lounges l
  order by score desc, l.name
  limit least(p_limit, 100);
$$;

-- Affollamento live (ultime 3h): visibile SOLO a chi ha contribuito nelle ultime 24h
create or replace function public.live_occupancy(p_lounge text)
returns table (reports bigint, empty bigint, normal bigint, full_ bigint, avg_queue numeric, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (
    select 1 from checkins where user_id = auth.uid() and occupancy is not null
      and created_at > now() - interval '24 hours') then
    return;  -- niente dato a chi non contribuisce
  end if;
  return query
    select count(*),
      count(*) filter (where occupancy = 'empty'),
      count(*) filter (where occupancy = 'normal'),
      count(*) filter (where occupancy = 'full'),
      round(avg(queue_minutes)::numeric, 0),
      max(created_at)
    from checkins
    where lounge_id = p_lounge and occupancy is not null and created_at > now() - interval '3 hours';
end $$;

-- Dashboard personale
create or replace function public.my_stats()
returns table (checkins bigint, lounges bigint, airports bigint, countries bigint,
               top_lounge_id text, top_lounge_name text, top_lounge_visits bigint, ratings bigint, favorites bigint)
language sql stable security definer set search_path = public as $$
  with mine as (
    select c.lounge_id, l.name, l.airport_iata, a.country
    from checkins c join lounges l on l.id = c.lounge_id join airports a on a.iata = l.airport_iata
    where c.user_id = auth.uid()
  ), top as (
    select lounge_id, name, count(*) n from mine group by 1,2 order by n desc, name limit 1
  )
  select (select count(*) from mine),
         (select count(distinct lounge_id) from mine),
         (select count(distinct airport_iata) from mine),
         (select count(distinct country) from mine),
         (select lounge_id from top), (select name from top), (select n from top),
         (select count(*) from ratings where user_id = auth.uid()),
         (select count(*) from favorites where user_id = auth.uid())
  where auth.uid() is not null;
$$;

revoke all on function public.my_stats() from anon;
grant execute on function public.lounge_stats(text), public.lounge_ranking(text,int) to anon, authenticated;
grant execute on function public.live_occupancy(text), public.my_stats() to authenticated;
