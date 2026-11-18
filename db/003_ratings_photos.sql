-- LoungeCompy · step 2: voti+commenti leggibili con autore, foto con moderazione, nome profilo

-- FK verso profiles per poter leggere l'autore insieme al voto (PostgREST embed)
alter table public.ratings  drop constraint if exists ratings_profile_fk;
alter table public.ratings  add  constraint ratings_profile_fk  foreign key (user_id) references public.profiles(id) on delete cascade;
alter table public.checkins drop constraint if exists checkins_profile_fk;
alter table public.checkins add  constraint checkins_profile_fk foreign key (user_id) references public.profiles(id) on delete cascade;

-- ========== FOTO ==========
create table if not exists public.photos (
  id uuid primary key default gen_random_uuid(),
  lounge_id text not null references public.lounges(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  path text not null unique,                 -- oggetto nel bucket lounge-photos
  approved boolean not null default false,   -- moderazione: true solo a mano
  created_at timestamptz not null default now()
);
create index if not exists photos_lounge_idx on public.photos(lounge_id, approved, created_at desc);
alter table public.photos enable row level security;
drop policy if exists "foto approvate o mie" on public.photos;
create policy "foto approvate o mie" on public.photos for select using (approved or auth.uid() = user_id);
drop policy if exists "carico foto dopo check-in" on public.photos;
create policy "carico foto dopo check-in" on public.photos for insert with check (
  auth.uid() = user_id and approved = false
  and exists (select 1 from public.checkins c where c.user_id = auth.uid() and c.lounge_id = photos.lounge_id)
  and (select count(*) from public.photos p where p.user_id = auth.uid() and p.created_at > now() - interval '1 day') < 10
);
drop policy if exists "cancello le mie foto" on public.photos;
create policy "cancello le mie foto" on public.photos for delete using (auth.uid() = user_id);

-- bucket pubblico in lettura, solo JPEG, max 3 MB; ognuno scrive solo nella propria cartella {uid}/
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lounge-photos', 'lounge-photos', true, 3145728, '{image/jpeg}')
on conflict (id) do update set public = true, file_size_limit = 3145728, allowed_mime_types = '{image/jpeg}';
drop policy if exists "lounge-photos lettura" on storage.objects;
create policy "lounge-photos lettura" on storage.objects for select using (bucket_id = 'lounge-photos');
drop policy if exists "lounge-photos carico nella mia cartella" on storage.objects;
create policy "lounge-photos carico nella mia cartella" on storage.objects for insert to authenticated
  with check (bucket_id = 'lounge-photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "lounge-photos cancello le mie" on storage.objects;
create policy "lounge-photos cancello le mie" on storage.objects for delete to authenticated
  using (bucket_id = 'lounge-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ========== I MIEI CHECK-IN PER LOUNGE (per sapere se posso votare/caricare) ==========
create or replace function public.my_checkins(p_lounge text)
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from checkins where user_id = auth.uid() and lounge_id = p_lounge;
$$;
revoke all on function public.my_checkins(text) from anon;
grant execute on function public.my_checkins(text) to authenticated;

-- ========== LE MIE ULTIME VISITE (dashboard) ==========
create or replace function public.my_recent()
returns table (lounge_id text, name text, airport_iata text, visits bigint, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.lounge_id, l.name, l.airport_iata, count(*), max(c.created_at)
  from checkins c join lounges l on l.id = c.lounge_id
  where c.user_id = auth.uid()
  group by 1,2,3 order by max(c.created_at) desc limit 20;
$$;
revoke all on function public.my_recent() from anon;
grant execute on function public.my_recent() to authenticated;
