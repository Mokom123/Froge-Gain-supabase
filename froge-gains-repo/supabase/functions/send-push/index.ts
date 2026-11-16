// Sends a phone notification whenever a row is added to the notifications table.
// Called by a database trigger (phase13b_update.sql). Needs TWO secrets:
//   FCM_SERVICE_ACCOUNT = the whole contents of the Firebase service-account .json file
//   PUSH_SECRET         = a long random password (the same one is put in phase13b_update.sql)
// Turn "Enforce JWT verification" OFF for this function; the PUSH_SECRET check protects it instead.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const b64url = (data: ArrayBuffer | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function accessToken(sa: { client_email: string; private_key: string }) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${claim}`));
  const jwt = `${head}.${claim}.${b64url(sig)}`;
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error("token: " + JSON.stringify(j));
  return j.access_token as string;
}

Deno.serve(async (req) => {
  try {
    const secret = Deno.env.get("PUSH_SECRET");
    if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("no", { status: 401 });
    const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!raw) return new Response("FCM_SERVICE_ACCOUNT secret missing", { status: 500 });
    const sa = JSON.parse(raw);
    const payload = await req.json();
    const n = payload.record ?? payload;
    if (!n?.title) return new Response("nothing to send");

    const token = await accessToken(sa);
    const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
    const base = {
      notification: { title: String(n.title), body: String(n.body ?? "") },
      data: {
        kind: String(n.kind ?? ""),
        task_id: n.task_id ? String(n.task_id) : "",
        actor_id: n.actor_id ? String(n.actor_id) : "",
        game_id: n.game_id ? String(n.game_id) : "",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
      android: { priority: "HIGH", notification: { sound: "default", default_vibrate_timings: true } },
    };
    const send = (target: Record<string, string>) =>
      fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ message: { ...base, ...target } }),
      });

    // For everybody (new tasks): send to the "all" group. For one person (follows): send to their phones.
    if (!n.user_id) {
      const r = await send({ topic: "all" });
      return new Response(await r.text(), { status: r.ok ? 200 : 500 });
    }
    const { data: rows } = await admin.from("device_tokens").select("token").eq("user_id", n.user_id);
    for (const row of rows ?? []) {
      const r = await send({ token: row.token });
      if (!r.ok) {
        const t = await r.text();
        // Phone no longer has the app: forget its token.
        if (t.includes("UNREGISTERED") || t.includes("NOT_FOUND") || t.includes("INVALID_ARGUMENT")) {
          await admin.from("device_tokens").delete().eq("token", row.token);
        }
      }
    }
    return new Response("ok");
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
