// Called by the app to start linking an X account. Keep "Enforce JWT verification" turned ON.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const CLIENT_ID = Deno.env.get("X_CLIENT_ID")!;
const admin = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (b: unknown) =>
  new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: u } = await admin.auth.getUser(jwt);
  const user = u?.user;
  if (!user) return json({ error: "auth", message: "Please log in again." });
  if (!CLIENT_ID) return json({ error: "setup", message: "X is not set up yet (missing X_CLIENT_ID)." });

  const state = crypto.randomUUID().replaceAll("-", "");
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)));
  const challenge = b64url(new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
  ));

  await admin.from("x_oauth_states").delete().eq("user_id", user.id);
  const { error } = await admin.from("x_oauth_states").insert({ state, user_id: user.id, verifier });
  if (error) return json({ error: "db", message: error.message });

  const q = new URLSearchParams({
    response_type: "code",
    client_id: CLIENT_ID,
    redirect_uri: `${URL_}/functions/v1/x-callback`,
    scope: "users.read tweet.read",
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  return json({ url: `https://x.com/i/oauth2/authorize?${q}` });
});
