// Telegram calls this when someone messages the bot. Deploy with "Enforce JWT verification" turned OFF.
// It links a Telegram account to a Froge account when the person presses Start from the app.
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN")!;
const SECRET = Deno.env.get("TELEGRAM_WEBHOOK_SECRET")!;
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

async function reply(chatId: number, text: string) {
  await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text }),
  });
}

Deno.serve(async (req) => {
  if (req.headers.get("x-telegram-bot-api-secret-token") !== SECRET) {
    return new Response("forbidden", { status: 403 });
  }
  const update = await req.json().catch(() => null);
  const msg = update?.message;
  if (!msg?.text || msg.chat?.type !== "private") return new Response("ok");

  const m = msg.text.match(/^\/start\s+([A-Za-z0-9_-]{8,64})$/);
  if (!m) {
    await reply(msg.chat.id, "Hi! To link your Telegram, open Froge Gains, go to Settings > Link accounts > Telegram, and tap Link.");
    return new Response("ok");
  }

  const { data: row } = await admin
    .from("telegram_link_codes").select("user_id, created_at").eq("code", m[1]).maybeSingle();
  if (!row || Date.now() - new Date(row.created_at).getTime() > 15 * 60 * 1000) {
    await reply(msg.chat.id, "This link has expired. Go back to the app and tap Link again.");
    return new Response("ok");
  }

  const { error } = await admin.from("telegram_links").upsert({
    user_id: row.user_id,
    tg_id: msg.from.id,
    tg_username: msg.from.username ?? null,
  }, { onConflict: "user_id" });

  await admin.from("telegram_link_codes").delete().eq("code", m[1]);

  if (error) {
    await reply(msg.chat.id, "This Telegram account is already linked to another Froge account.");
  } else {
    await reply(msg.chat.id, "Linked! You can go back to Froge Gains and verify your Telegram tasks.");
  }
  return new Response("ok");
});
