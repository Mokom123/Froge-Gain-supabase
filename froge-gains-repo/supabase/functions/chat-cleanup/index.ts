// Deletes chat photos, videos and voice notes older than 14 days. The messages stay and show
// "Media not available" with their small thumbnail. Run nightly by phase17b_schedule.sql.
// Secret: PUSH_SECRET (the same one send-push uses). Deploy with "Enforce JWT verification" turned OFF.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_SECRET");
  if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("no", { status: 401 });
  try {
    let total = 0;
    // up to 10 rounds of 500 files per run
    for (let i = 0; i < 10; i++) {
      const { data, error } = await admin.rpc("chat_expired_files");
      if (error) return new Response(error.message, { status: 500 });
      const names = (data ?? []).map((r: { name: string }) => r.name);
      if (names.length === 0) break;
      const rm = await admin.storage.from("chat").remove(names);
      if (rm.error) return new Response(rm.error.message, { status: 500 });
      await admin.rpc("chat_mark_gone", { p_names: names });
      total += names.length;
      if (names.length < 500) break;
    }
    return new Response(`deleted ${total}`);
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
