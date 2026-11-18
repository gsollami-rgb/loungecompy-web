-- LoungeCompy · step 3: ruoli admin, registro azioni, check-in con posizione, coordinate aeroporti

-- ========== RUOLI ==========
alter table public.profiles add column if not exists role text not null default 'user' check (role in ('user','admin'));
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from profiles where id = auth.uid()), false);
$$;
grant execute on function public.is_admin() to anon, authenticated;

create table if not exists public.admin_log (
  id bigint generated always as identity primary key,
  admin_id uuid not null references public.profiles(id) on delete set null,
  action text not null,
  target_type text, target_ref text, note text,
  created_at timestamptz not null default now()
);
alter table public.admin_log enable row level security;
drop policy if exists "log visibile agli admin" on public.admin_log;
create policy "log visibile agli admin" on public.admin_log for select using (public.is_admin());

-- ========== COORDINATE AEROPORTI ==========
alter table public.airports add column if not exists lat double precision, add column if not exists lon double precision;

-- ========== CHECK-IN: serve la posizione (gli admin possono fare check-in di test) ==========
drop policy if exists "faccio check-in" on public.checkins;
create policy "faccio check-in" on public.checkins for insert with check (
  auth.uid() = user_id
  and (geo_verified or public.is_admin())
  and not exists (select 1 from public.checkins c where c.user_id = auth.uid()
                  and c.lounge_id = checkins.lounge_id and c.created_at > now() - interval '2 hours')
);
drop policy if exists "admin vede i check-in" on public.checkins;
create policy "admin vede i check-in" on public.checkins for select using (public.is_admin());

-- ========== POTERI ADMIN SU FOTO / VOTI / SEGNALAZIONI ==========
drop policy if exists "admin modera foto" on public.photos;
create policy "admin modera foto" on public.photos for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin elimina foto" on public.photos;
create policy "admin elimina foto" on public.photos for delete using (public.is_admin());
drop policy if exists "lounge-photos admin elimina" on storage.objects;
create policy "lounge-photos admin elimina" on storage.objects for delete to authenticated
  using (bucket_id = 'lounge-photos' and public.is_admin());

drop policy if exists "admin nasconde voti" on public.ratings;
create policy "admin nasconde voti" on public.ratings for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin vede tutti i voti" on public.ratings;
create policy "admin vede tutti i voti" on public.ratings for select using (public.is_admin());

alter table public.reports add column if not exists status text not null default 'open' check (status in ('open','resolved','dismissed')),
  add column if not exists resolved_by uuid, add column if not exists resolved_at timestamptz;
drop policy if exists "admin legge segnalazioni" on public.reports;
create policy "admin legge segnalazioni" on public.reports for select using (public.is_admin());
drop policy if exists "admin chiude segnalazioni" on public.reports;
create policy "admin chiude segnalazioni" on public.reports for update using (public.is_admin()) with check (public.is_admin());

-- ========== FUNZIONI PANNELLO ==========
create or replace function public.admin_overview()
returns table (users bigint, users_7d bigint, checkins_7d bigint, photos_pending bigint, reports_open bigint, ratings bigint, admins bigint)
language sql stable security definer set search_path = public as $$
  select (select count(*) from profiles),
         (select count(*) from profiles where created_at > now() - interval '7 days'),
         (select count(*) from checkins where created_at > now() - interval '7 days'),
         (select count(*) from photos where not approved),
         (select count(*) from reports where status = 'open'),
         (select count(*) from ratings where not hidden),
         (select count(*) from profiles where role = 'admin')
  where public.is_admin();
$$;

create or replace function public.admin_pending_photos()
returns table (id uuid, path text, lounge_id text, lounge_name text, airport_iata text, user_name text, user_email text, created_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  select p.id, p.path, p.lounge_id, l.name, l.airport_iata, pr.display_name, u.email, p.created_at
  from photos p join lounges l on l.id = p.lounge_id join profiles pr on pr.id = p.user_id join auth.users u on u.id = p.user_id
  where not p.approved and public.is_admin() order by p.created_at;
$$;

create or replace function public.admin_moderate_photo(p_id uuid, p_approve boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  select path into v_path from photos where id = p_id;
  if v_path is null then return null; end if;
  if p_approve then update photos set approved = true where id = p_id;
  else delete from photos where id = p_id; end if;
  insert into admin_log (admin_id, action, target_type, target_ref) values (auth.uid(), case when p_approve then 'photo_approve' else 'photo_reject' end, 'photo', p_id::text);
  return v_path;  -- il client cancella l'oggetto nel bucket se rifiutata
end $$;

create or replace function public.admin_reports()
returns table (id bigint, target_type text, target_ref text, reason text, reporter text, created_at timestamptz, detail text, lounge_id text)
language sql stable security definer set search_path = public as $$
  select r.id, r.target_type, r.target_ref, r.reason, pr.display_name, r.created_at,
    case r.target_type
      when 'rating' then (select coalesce(x.comment,'') || ' (' || x.stars || '★)' from ratings x where x.user_id::text = split_part(r.target_ref,'|',1) and x.lounge_id = split_part(r.target_ref,'|',2))
      when 'photo'  then (select x.path from photos x where x.id::text = r.target_ref)
      else r.target_ref end,
    case r.target_type when 'rating' then split_part(r.target_ref,'|',2) when 'photo' then (select x.lounge_id from photos x where x.id::text = r.target_ref) else r.target_ref end
  from reports r left join profiles pr on pr.id = r.user_id
  where r.status = 'open' and public.is_admin() order by r.created_at;
$$;

create or replace function public.admin_resolve_report(p_id bigint, p_action text)
returns text language plpgsql security definer set search_path = public as $$
declare r reports%rowtype; v_path text;
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  select * into r from reports where id = p_id;
  if r.id is null then return null; end if;
  if p_action = 'hide_rating' and r.target_type = 'rating' then
    update ratings set hidden = true where user_id::text = split_part(r.target_ref,'|',1) and lounge_id = split_part(r.target_ref,'|',2);
  elsif p_action = 'delete_photo' and r.target_type = 'photo' then
    select path into v_path from photos where id::text = r.target_ref;
    delete from photos where id::text = r.target_ref;
  end if;
  update reports set status = case when p_action = 'dismiss' then 'dismissed' else 'resolved' end, resolved_by = auth.uid(), resolved_at = now() where id = p_id;
  insert into admin_log (admin_id, action, target_type, target_ref) values (auth.uid(), 'report_' || p_action, r.target_type, r.target_ref);
  return v_path;
end $$;

create or replace function public.admin_list_admins()
returns table (id uuid, email text, display_name text, created_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email, p.display_name, p.created_at from profiles p join auth.users u on u.id = p.id
  where p.role = 'admin' and public.is_admin() order by p.created_at;
$$;

create or replace function public.admin_set_role(p_email text, p_role text)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  if p_role not in ('user','admin') then raise exception 'bad role'; end if;
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then return false; end if;             -- deve aver fatto almeno un accesso
  if v_id = auth.uid() then raise exception 'non puoi cambiare il tuo ruolo'; end if;
  update profiles set role = p_role where id = v_id;
  insert into admin_log (admin_id, action, target_type, target_ref) values (auth.uid(), 'role_' || p_role, 'user', lower(trim(p_email)));
  return true;
end $$;

create or replace function public.admin_users(p_limit int default 30)
returns table (id uuid, email text, display_name text, role text, created_at timestamptz, checkins bigint, ratings bigint)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email, p.display_name, p.role, p.created_at,
    (select count(*) from checkins c where c.user_id = p.id), (select count(*) from ratings r where r.user_id = p.id)
  from profiles p join auth.users u on u.id = p.id
  where public.is_admin() order by p.created_at desc limit least(p_limit, 200);
$$;

create or replace function public.admin_recent_log(p_limit int default 50)
returns table (created_at timestamptz, admin text, action text, target_type text, target_ref text)
language sql stable security definer set search_path = public as $$
  select l.created_at, p.display_name, l.action, l.target_type, l.target_ref from admin_log l left join profiles p on p.id = l.admin_id
  where public.is_admin() order by l.created_at desc limit least(p_limit, 200);
$$;

revoke all on function public.admin_overview(), public.admin_pending_photos(), public.admin_moderate_photo(uuid,boolean), public.admin_reports(),
  public.admin_resolve_report(bigint,text), public.admin_list_admins(), public.admin_set_role(text,text), public.admin_users(int), public.admin_recent_log(int) from anon, public;
grant execute on function public.admin_overview(), public.admin_pending_photos(), public.admin_moderate_photo(uuid,boolean), public.admin_reports(),
  public.admin_resolve_report(bigint,text), public.admin_list_admins(), public.admin_set_role(text,text), public.admin_users(int), public.admin_recent_log(int) to authenticated;

-- il mio ruolo (per mostrare il pannello)
create or replace function public.my_role() returns text language sql stable security definer set search_path = public as $$
  select coalesce((select role from profiles where id = auth.uid()), 'anon');
$$;
grant execute on function public.my_role() to authenticated;
