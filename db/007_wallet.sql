-- Wallet sincronizzato per gli utenti registrati (gli ospiti restano solo in locale)
create table if not exists public.user_wallet (
  user_id uuid primary key references public.profiles(id) on delete cascade default auth.uid(),
  items text[] not null default '{}',
  updated_at timestamptz not null default now()
);
alter table public.user_wallet enable row level security;
drop policy if exists "il mio wallet" on public.user_wallet;
create policy "il mio wallet" on public.user_wallet for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
