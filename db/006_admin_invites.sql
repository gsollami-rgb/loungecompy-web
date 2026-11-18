-- Admin su invito: se l'email è in lista, al primo accesso il profilo nasce già admin
create table if not exists public.admin_invites (email text primary key, invited_by uuid, created_at timestamptz not null default now());
alter table public.admin_invites enable row level security;
drop policy if exists "inviti visibili agli admin" on public.admin_invites;
create policy "inviti visibili agli admin" on public.admin_invites for select using (public.is_admin());

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, avatar_url, role)
  values (new.id,
          left(coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)), 40),
          new.raw_user_meta_data->>'avatar_url',
          case when exists (select 1 from public.admin_invites i where i.email = lower(new.email)) then 'admin' else 'user' end)
  on conflict (id) do nothing;
  return new;
end $$;

-- admin_set_role: se l'utente non esiste ancora, lascia un invito invece di fallire
create or replace function public.admin_set_role(p_email text, p_role text)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid; v_email text := lower(trim(p_email));
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  if p_role not in ('user','admin') then raise exception 'bad role'; end if;
  select id into v_id from auth.users where lower(email) = v_email;
  if v_id is null then
    if p_role = 'admin' then insert into public.admin_invites (email, invited_by) values (v_email, auth.uid()) on conflict do nothing;
    else delete from public.admin_invites where email = v_email; end if;
    insert into admin_log (admin_id, action, target_type, target_ref) values (auth.uid(), 'invite_' || p_role, 'user', v_email);
    return false;   -- false = non ancora registrato, invito lasciato
  end if;
  if v_id = auth.uid() then raise exception 'non puoi cambiare il tuo ruolo'; end if;
  update profiles set role = p_role where id = v_id;
  if p_role = 'user' then delete from public.admin_invites where email = v_email; end if;
  insert into admin_log (admin_id, action, target_type, target_ref) values (auth.uid(), 'role_' || p_role, 'user', v_email);
  return true;
end $$;

create or replace function public.admin_list_admins()
returns table (id uuid, email text, display_name text, created_at timestamptz, pending boolean)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email, p.display_name, p.created_at, false from profiles p join auth.users u on u.id = p.id where p.role = 'admin' and public.is_admin()
  union all
  select null, i.email, null, i.created_at, true from admin_invites i where public.is_admin() and not exists (select 1 from auth.users u where lower(u.email) = i.email)
  order by 5, 4;
$$;

-- i due admin richiesti da Nicola (18/11/2026)
update public.profiles set role = 'admin' where id = (select id from auth.users where lower(email) = 'sganjalosi@gmail.com');
insert into public.admin_invites (email) values ('sollamigiovanni@gmail.com') on conflict do nothing;
update public.profiles p set role = 'admin' from auth.users u where u.id = p.id and lower(u.email) = 'sollamigiovanni@gmail.com';
select u.email, p.role from auth.users u join public.profiles p on p.id = u.id order by p.created_at;
