// Called by the app. Keep "Enforce JWT verification" turned ON for this one.
// Actions: link (start linking), verify (check a join task and pay), setup (admins: connect the bot).
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET")!;
const URL_ = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (b: unknown) =>
  new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
const fail = (error: string, message: string) => json({ error, message });
const tg = async (method: string, body: unknown = {}) =>
  (await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  })).json();

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: u } = await admin.auth.getUser(jwt);
  const user = u?.user;
  if (!user) return fail("auth", "Please log in again.");
  const body = await req.json().catch(() => ({}));

  if (body.action === "link") {
    const me = await tg("getMe");
    if (!me.ok) return fail("bot", "The Telegram bot is not set up yet.");
    await admin.from("telegram_link_codes").delete().eq("user_id", user.id);
    const code = crypto.randomUUID().replaceAll("-", "");
    const { error } = await admin.from("telegram_link_codes").insert({ code, user_id: user.id });
    if (error) return fail("db", error.message);
    return json({ url: `https://t.me/${me.result.username}?start=${code}` });
  }

  if (body.action === "verify") {
    const { data: task } = await admin.from("tasks").select("*").eq("id", body.task_id).maybeSingle();
    if (!task || !task.active || task.platform !== "telegram") return fail("task", "Task not available.");
    const m = String(task.url).match(/t\.me\/([A-Za-z0-9_]{4,})/);
    if (!m || ["joinchat", "c", "+"].includes(m[1])) {
      return fail("link", "This task needs a public group link like t.me/groupname.");
    }
    const { data: link } = await admin.from("telegram_links").select("tg_id").eq("user_id", user.id).maybeSingle();
    if (!link) return fail("not_linked", "Link your Telegram account first (Settings > Link accounts).");

    const r = await tg("getChatMember", { chat_id: "@" + m[1], user_id: link.tg_id });
    if (!r.ok) return fail("telegram", "Could not check the group. Make sure the Froge bot is an admin there.");
    const s = r.result.status;
    const inside = ["creator", "administrator", "member"].includes(s) || (s === "restricted" && r.result.is_member);
    if (!inside) return fail("not_member", "You have not joined the group yet. Join it, then tap Verify again.");

    const { data: pts, error } = await admin.rpc("claim_telegram_task", { p_user: user.id, p_task: String(task.id) });
    if (error) return fail("claim", error.message);
    return json({ points: pts });
  }

  if (body.action === "setup") {
    const { data: p } = await admin.from("profiles").select("is_admin").eq("id", user.id).maybeSingle();
    if (!p?.is_admin) return fail("admin", "Admins only.");
    const r = await tg("setWebhook", {
      url: `${URL_}/functions/v1/telegram-webhook`,
      secret_token: SECRET,
      allowed_updates: ["message"],
    });
    const me = await tg("getMe");
    return json({ ok: r.ok, bot: me.result?.username, message: r.description ?? "Webhook set" });
  }

  return fail("action", "Unknown action.");
});
