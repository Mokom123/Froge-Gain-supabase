// Deletes every status older than 24 hours: first the uploaded photo or video file, then the status row itself,
// so nothing is kept. Run every 15 minutes by phase18b_schedule.sql.
// Secret: PUSH_SECRET (the same one send-push uses). Deploy with "Enforce JWT verification" turned OFF.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const marker = "/object/public/status/";

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_SECRET");
  if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("no", { status: 401 });
  try {
    let files = 0, rows = 0;
    for (let i = 0; i < 10; i++) {
      const { data, error } = await admin.rpc("status_expired");
      if (error) return new Response(error.message, { status: 500 });
      const list = (data ?? []) as { id: number; media_url: string | null }[];
      if (list.length === 0) break;
      const paths = list
        .map((r) => (r.media_url && r.media_url.includes(marker) ? decodeURIComponent(r.media_url.split(marker)[1].split("?")[0]) : null))
        .filter((p): p is string => !!p);
      if (paths.length > 0) {
        const rm = await admin.storage.from("status").remove(paths);
        if (rm.error) return new Response(rm.error.message, { status: 500 }); // keep the rows so it is retried
        files += paths.length;
      }
      const del = await admin.rpc("status_purge", { p_ids: list.map((r) => r.id) });
      if (del.error) return new Response(del.error.message, { status: 500 });
      rows += list.length;
      if (list.length < 200) break;
    }
    return new Response(`deleted ${rows} statuses, ${files} files`);
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});
