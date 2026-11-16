// X sends the person's browser here after they approve. Deploy with "Enforce JWT verification" turned OFF.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const CLIENT_ID = Deno.env.get("X_CLIENT_ID")!;
const CLIENT_SECRET = Deno.env.get("X_CLIENT_SECRET")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const text = (t: string, status = 200) =>
  new Response(t, { status, headers: { "content-type": "text/plain; charset=utf-8" } });

Deno.serve(async (req) => {
  const q = new URL(req.url).searchParams;
  const code = q.get("code"), state = q.get("state");
  if (q.get("error")) return text("X sign-in was cancelled. Go back to Froge Gains and try again.");
  if (!code || !state) return text("Missing information. Go back to Froge Gains and try again.", 400);

  const { data: row } = await admin
    .from("x_oauth_states").select("user_id, verifier, created_at").eq("state", state).maybeSingle();
  if (!row || Date.now() - new Date(row.created_at).getTime() > 15 * 60 * 1000) {
    return text("This link has expired. Go back to Froge Gains and tap Link again.", 400);
  }
  await admin.from("x_oauth_states").delete().eq("state", state);

  const tokenRes = await fetch("https://api.x.com/2/oauth2/token", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      authorization: "Basic " + btoa(`${CLIENT_ID}:${CLIENT_SECRET}`),
    },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: `${URL_}/functions/v1/x-callback`,
      code_verifier: row.verifier,
      client_id: CLIENT_ID,
    }),
  });
  const tok = await tokenRes.json().catch(() => ({}));
  if (!tok.access_token) {
    console.log("x token error", JSON.stringify(tok));
    return text("X did not accept the sign-in. Please try again in a minute.", 400);
  }

  const meRes = await fetch("https://api.x.com/2/users/me", {
    headers: { authorization: `Bearer ${tok.access_token}` },
  });
  const me = await meRes.json().catch(() => ({}));
  if (!me.data?.id) {
    console.log("x me error", JSON.stringify(me));
    return text("Could not read your X profile. Please try again.", 400);
  }

  const { error } = await admin.from("x_links").upsert(
    { user_id: row.user_id, x_id: me.data.id, x_username: me.data.username ?? null },
    { onConflict: "user_id" },
  );
  if (error) return text("This X account is already linked to another Froge account.", 409);
  return text(`Linked @${me.data.username}. You can close this tab and go back to Froge Gains.`);
});
