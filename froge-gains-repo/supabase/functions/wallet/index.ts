// Proves a person owns a wallet: they sign a message in MetaMask, we check it.
// The app never holds funds. Deploy with "Enforce JWT verification" turned ON. No secrets needed.
import { createClient } from "npm:@supabase/supabase-js@2";
import { verifyMessage } from "npm:viem@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (b: unknown) => new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
const bad = (message: string, error = "bad") => json({ error, message });
const isAddr = (a: unknown) => typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a);

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: u } = await admin.auth.getUser(jwt);
  const user = u?.user;
  if (!user) return bad("Please log in again.", "auth");
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }

  // 1) Give the app a message to sign.
  if (body.action === "nonce") {
    if (!isAddr(body.address)) return bad("Invalid address.");
    const message = `Froge Gains wallet verification\nAddress: ${(body.address as string).toLowerCase()}\nCode: ${crypto.randomUUID()}`;
    await admin.from("wallet_nonces").upsert({ user_id: user.id, message, created_at: new Date().toISOString() });
    return json({ message });
  }

  // 2) Check the signature and save the wallet as verified.
  if (body.action === "verify") {
    const address = body.address as string;
    if (!isAddr(address) || typeof body.signature !== "string") return bad("Invalid request.");
    const { data: n } = await admin.from("wallet_nonces").select("message, created_at").eq("user_id", user.id).maybeSingle();
    if (!n || Date.now() - new Date(n.created_at).getTime() > 10 * 60 * 1000) return bad("The request expired. Try again.");
    if (!n.message.includes(address.toLowerCase())) return bad("Address does not match the request.");
    let ok = false;
    try {
      ok = await verifyMessage({ address: address as `0x${string}`, message: n.message, signature: body.signature as `0x${string}` });
    } catch { ok = false; }
    if (!ok) return bad("The signature does not match this wallet.");
    const { data: other } = await admin.from("profiles").select("id").ilike("wallet_address", address).eq("wallet_verified", true).neq("id", user.id).limit(1);
    if (other && other.length) return bad("This wallet is already linked to another account.");
    const { error } = await admin.from("profiles").update({ wallet_address: address, wallet_verified: true }).eq("id", user.id);
    if (error) return bad(error.message, "db");
    await admin.from("wallet_nonces").delete().eq("user_id", user.id);
    return json({ ok: true });
  }

  return bad("Unknown action.");
});
