// 404 Gaming Zone — booking-alert (Supabase Edge Function)
// Deploy with "Verify JWT" OFF. It is safe to call by anyone:
//   GET   -> the public key phones need to subscribe
//   POST  -> sends a notification for every pending booking not alerted yet
//   POST {test:true} with an owner's sign-in -> test notification to that owner
// It keeps no secret in code: the signing keys live in gz_push_keys.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

function pkTime(ms: number) {
  const d = new Date(Number(ms) + 5 * 3600000);
  let h = d.getUTCHours(); const m = d.getUTCMinutes(), ap = h >= 12 ? "PM" : "AM";
  h = h % 12 || 12;
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return `${days[d.getUTCDay()]} ${d.getUTCDate()}, ${h}${m ? ":" + String(m).padStart(2, "0") : ""} ${ap}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    let { data: k } = await db.from("gz_push_keys").select("*").eq("id", 1).maybeSingle();
    if (!k) {
      const v = webpush.generateVAPIDKeys();
      await db.from("gz_push_keys").insert({ id: 1, public_key: v.publicKey, private_key: v.privateKey });
      ({ data: k } = await db.from("gz_push_keys").select("*").eq("id", 1).maybeSingle());
    }
    if (!k) return json({ error: "keys not ready" }, 500);
    if (req.method === "GET") return json({ publicKey: k.public_key });

    webpush.setVapidDetails("mailto:alerts@404gamingzone.pk", k.public_key, k.private_key);
    const body = await req.json().catch(() => ({}));

    let subs: any[] = [];
    let notes: { title: string; body: string; tag: string }[] = [];

    if (body && body.test) {
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u } = await db.auth.getUser(token);
      if (!u?.user) return json({ error: "sign in first" }, 401);
      const { data: p } = await db.from("profiles").select("role").eq("id", u.user.id).maybeSingle();
      if (p?.role !== "owner") return json({ error: "owners only" }, 403);
      ({ data: subs } = await db.from("gz_push_subs").select("*").eq("user_id", u.user.id));
      notes = [{ title: "404 alerts are working", body: "New bookings will show up like this.", tag: "test" }];
    } else {
      // Claim the bookings first, so two calls can never alert twice.
      const { data: rows } = await db.from("gz_bookings")
        .update({ alerted_at: new Date().toISOString() })
        .is("alerted_at", null).eq("state", "pending")
        .select("id,booking_no,customer_name,machine_id,start_time,paid");
      if (!rows || !rows.length) return json({ bookings: 0, sent: 0 });
      ({ data: subs } = await db.from("gz_push_subs").select("*"));
      notes = rows.map((r: any) => ({
        title: `New booking #${r.booking_no} to check`,
        body: `${r.customer_name} · ${r.machine_id} · ${pkTime(r.start_time)} · says paid Rs ${Number(r.paid).toLocaleString("en-PK")}`,
        tag: "bk-" + r.id,
      }));
    }

    let sent = 0, failed = 0;
    for (const n of notes) {
      for (const s of subs || []) {
        try {
          await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            JSON.stringify(n), { TTL: 3600, urgency: "high" });
          sent++;
        } catch (e: any) {
          failed++;
          if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("gz_push_subs").delete().eq("id", s.id);
        }
      }
    }
    return json({ bookings: body?.test ? 0 : notes.length, phones: (subs || []).length, sent, failed });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
