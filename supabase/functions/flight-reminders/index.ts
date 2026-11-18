// Supabase Edge Function: manda la notifica push "domani voli da X: entri gratis in Y" per i voli con notify_at scaduto.
// Deploy: dal dashboard Supabase (Edge Functions → Deploy new function → incolla questo file) oppure `supabase functions deploy flight-reminders`.
// Secrets richiesti (Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT=mailto:leonenicola10@gmail.com
// Schedulazione: Integrations → Cron → ogni ora: select net.http_post(url:='https://yavlmzltdosimuzfksak.supabase.co/functions/v1/flight-reminders', headers:='{"Authorization":"Bearer <SERVICE_ROLE_KEY>"}'::jsonb);
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3";

const LABEL: Record<string, string> = { free: "entri gratis", cond: "entri gratis a condizione", pay: "entri pagando", unk: "da verificare", no: "non entri" };

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(url, key);
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "mailto:leonenicola10@gmail.com", Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!);

  const { data: flights, error } = await sb.from("flights").select("id,user_id,airport_iata,flight_no,dep_at,lounge_id").is("notified_at", null).lte("notify_at", new Date().toISOString()).limit(200);
  if (error) return new Response(JSON.stringify({ error }), { status: 500 });
  let sent = 0, failed = 0;
  for (const f of flights ?? []) {
    const { data: subs } = await sb.from("push_subscriptions").select("endpoint,p256dh,auth").eq("user_id", f.user_id);
    const { data: ap } = await sb.from("airports").select("city,name").eq("iata", f.airport_iata).single();
    const { data: lg } = f.lounge_id ? await sb.from("lounges").select("name,ta,hours,price").eq("id", f.lounge_id).single() : { data: null };
    const dep = new Date(f.dep_at);
    const when = dep.toLocaleString("it-IT", { timeZone: "Europe/Rome", weekday: "long", hour: "2-digit", minute: "2-digit" });
    const body = lg
      ? `Domani ${when} da ${ap?.city ?? f.airport_iata} ${f.airport_iata}${f.flight_no ? " (" + f.flight_no + ")" : ""}. Lounge consigliata: ${lg.name}${lg.ta ? " · " + lg.ta : ""}. Apri l'app per vedere se entri gratis con le tue carte.`
      : `Domani ${when} da ${ap?.city ?? f.airport_iata} ${f.airport_iata}. Apri l'app: ti diciamo in quale lounge entri.`;
    const payload = JSON.stringify({ title: "Il tuo volo di domani · LoungeCompy", body, url: f.lounge_id ? `https://lounge-compy.com/#l=${f.lounge_id}` : "https://lounge-compy.com/", tag: "flight-" + f.id });
    for (const s of subs ?? []) {
      try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload); sent++; }
      catch (e: any) { failed++; if (e?.statusCode === 404 || e?.statusCode === 410) await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); }
    }
    await sb.from("flights").update({ notified_at: new Date().toISOString() }).eq("id", f.id);
  }
  return new Response(JSON.stringify({ flights: flights?.length ?? 0, sent, failed }), { headers: { "content-type": "application/json" } });
});
