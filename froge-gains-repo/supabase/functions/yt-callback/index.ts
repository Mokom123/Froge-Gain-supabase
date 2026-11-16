// Google sends the person's browser here after they approve. Deploy with "Enforce JWT verification" turned OFF.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const text = (t: string, status = 200) =>
  new Response(t, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

Deno.serve(async (req) => {
  const q = new URL(req.url).searchParams;
  const code = q.get("code"), state = q.get("state");
  if (q.get("error")) return text("YouTube sign-in was cancelled. Go back to Froge Gains and try again.");
  if (!code || !state) return text("Missing information. Go back to Froge Gains and try again.", 400);

  const { data: row } = await admin
    .from("yt_oauth_states").select("user_id, created_at").eq("state", state).maybeSingle();
  if (!row || Date.now() - new Date(row.created_at).getTime() > 15 * 60 * 1000) {
    return text("This link has expired. Go back to Froge Gains and tap Link again.", 400);
  }
  await admin.from("yt_oauth_states").delete().eq("state", state);

  const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      redirect_uri: `${URL_}/functions/v1/yt-callback`,
      grant_type: "authorization_code",
    }),
  });
  const tok = await tokenRes.json().catch(() => ({}));
  if (!tok.access_token) {
    console.log("google token error", JSON.stringify(tok));
    return text("Google did not accept the sign-in. Please try again in a minute.", 400);
  }
  if (!tok.refresh_token) {
    return text("Google did not give permission to check tasks later. Go to myaccount.google.com/permissions, remove Froge Gains, then link again.", 400);
  }

  const chRes = await fetch("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", {
    headers: { authorization: `Bearer ${tok.access_token}` },
  });
  const ch = await chRes.json().catch(() => ({}));
  const channel = ch.items?.[0];
  if (!channel?.id) {
    console.log("youtube channel error", JSON.stringify(ch));
    return text("This Google account has no YouTube channel. Create one on YouTube first, then link again.", 400);
  }

  const { error } = await admin.from("youtube_links").upsert(
    {
      user_id: row.user_id,
      channel_id: channel.id,
      channel_title: channel.snippet?.title ?? null,
      refresh_token: tok.refresh_token,
    },
    { onConflict: "user_id" },
  );
  if (error) return text("This YouTube channel is already linked to another Froge account.", 409);
  return text(`Linked ${channel.snippet?.title ?? "your channel"}. You can close this tab and go back to Froge Gains.`);
});
