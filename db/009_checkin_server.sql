-- 009: il check-in è verificato dal server, non dal client.
-- Il browser manda solo lat/lon; la distanza dall'aeroporto la calcola Postgres.
-- Niente più insert diretti su checkins: solo tramite la RPC do_checkin.

drop policy if exists "faccio check-in" on public.checkins;

create or replace function public.do_checkin(p_lounge_id text, p_occupancy text, p_lat double precision, p_lon double precision)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ap record; v_km double precision; v_ok boolean := false; v_adm boolean := public.is_admin();
begin
  if auth.uid() is null then raise exception 'auth' using errcode = '42501'; end if;
  if p_occupancy not in ('empty','normal','full') then raise exception 'occupancy'; end if;
  select a.iata, a.lat, a.lon into v_ap
    from public.lounges l join public.airports a on a.iata = l.airport_iata
   where l.id = p_lounge_id;
  if v_ap.iata is null then raise exception 'lounge'; end if;
  if p_lat is not null and p_lon is not null and v_ap.lat is not null then
    v_km := 2 * 6371 * asin(sqrt(
      power(sin(radians(v_ap.lat - p_lat) / 2), 2)
      + cos(radians(p_lat)) * cos(radians(v_ap.lat)) * power(sin(radians(v_ap.lon - p_lon) / 2), 2)));
    v_ok := v_km <= 6;
  end if;
  if not v_ok and not v_adm then
    return jsonb_build_object('ok', false, 'km', round(v_km::numeric), 'ap', v_ap.iata);
  end if;
  if exists (select 1 from public.checkins c where c.user_id = auth.uid()
             and c.lounge_id = p_lounge_id and c.created_at > now() - interval '2 hours') then
    return jsonb_build_object('ok', false, 'dup', true);
  end if;
  insert into public.checkins (user_id, lounge_id, occupancy, geo_verified)
  values (auth.uid(), p_lounge_id, p_occupancy, v_ok);
  return jsonb_build_object('ok', true, 'verified', v_ok, 'km', round(v_km::numeric));
end $$;
grant execute on function public.do_checkin(text, text, double precision, double precision) to authenticated;
