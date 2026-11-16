// Called by the app to start linking a YouTube channel. Keep "Enforce JWT verification" turned ON.
// Secrets needed: GOOGLE_CLIENT_ID (and GOOGLE_CLIENT_SECRET for yt-callback and yt-verify).
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (b: unknown) =>
  new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: u } = await admin.auth.getUser(jwt);
  const user = u?.user;
  if (!user) return json({ error: "auth", message: "Please log in again." });
  if (!CLIENT_ID) return json({ error: "setup", message: "YouTube is not set up yet (missing GOOGLE_CLIENT_ID)." });

  const state = crypto.randomUUID().replaceAll("-", "");
  await admin.from("yt_oauth_states").delete().eq("user_id", user.id);
  const { error } = await admin.from("yt_oauth_states").insert({ state, user_id: user.id });
  if (error) return json({ error: "db", message: error.message });

  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    redirect_uri: `${URL_}/functions/v1/yt-callback`,
    response_type: "code",
    scope: "https://www.googleapis.com/auth/youtube.readonly",
    access_type: "offline", // gives us a refresh token so tasks can be checked later
    prompt: "consent select_account",
    state,
  });
  return json({ url: `https://accounts.google.com/o/oauth2/v2/auth?${q}` });
});
