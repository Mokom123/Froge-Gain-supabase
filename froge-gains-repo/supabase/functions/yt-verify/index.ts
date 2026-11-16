// Checks a YouTube task with YouTube itself and pays the points. Keep "Enforce JWT verification" turned ON.
// Secrets: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2";

const CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID")!;
const CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET")!;
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const json = (b: unknown) =>
  new Response(JSON.stringify(b), { headers: { "content-type": "application/json" } });
const fail = (error: string, message: string) => json({ error, message });
const API = "https://www.googleapis.com/youtube/v3";

async function accessToken(refresh: string): Promise<string | null> {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      refresh_token: refresh,
      grant_type: "refresh_token",
    }),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.access_token) console.log("refresh failed", JSON.stringify(j));
  return j.access_token ?? null;
}

async function yt(path: string, token: string) {
  const r = await fetch(`${API}/${path}`, { headers: { authorization: `Bearer ${token}` } });
  const data = await r.json().catch(() => ({}));
  return { status: r.status, data, reason: String(data?.error?.errors?.[0]?.reason ?? "") };
}

const videoIdOf = (u: string) =>
  u.match(/(?:youtu\.be\/|[?&]v=|\/shorts\/|\/live\/|\/embed\/)([A-Za-z0-9_-]{11})/)?.[1] ?? null;

async function channelIdOf(url: string, token: string): Promise<string | null> {
  let m = url.match(/youtube\.com\/channel\/(UC[A-Za-z0-9_-]{22})/);
  if (m) return m[1];
  m = url.match(/youtube\.com\/(@[A-Za-z0-9._-]+)/);
  if (m) return (await yt(`channels?part=id&forHandle=${encodeURIComponent(m[1])}`, token)).data?.items?.[0]?.id ?? null;
  m = url.match(/youtube\.com\/user\/([A-Za-z0-9._-]+)/);
  if (m) return (await yt(`channels?part=id&forUsername=${encodeURIComponent(m[1])}`, token)).data?.items?.[0]?.id ?? null;
  const v = videoIdOf(url);
  if (v) return (await yt(`videos?part=snippet&id=${v}`, token)).data?.items?.[0]?.snippet?.channelId ?? null;
  return null;
}

Deno.serve(async (req) => {
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: u } = await admin.auth.getUser(jwt);
  const user = u?.user;
  if (!user) return fail("auth", "Please log in again.");
  const body = await req.json().catch(() => ({}));
  if (body.action !== "verify") return fail("action", "Unknown action.");

  const { data: task } = await admin.from("tasks").select("*").eq("id", body.task_id).maybeSingle();
  if (!task || !task.active || task.platform !== "youtube") return fail("task", "Task not available.");
  if (!["like", "comment", "subscribe"].includes(task.kind)) {
    return fail("kind", "This task type cannot be checked automatically.");
  }
  const { data: done } = await admin.from("completions").select("task_id")
    .eq("user_id", user.id).eq("task_id", String(task.id)).maybeSingle();
  if (done) return fail("done", "You already completed this task.");

  const { data: link } = await admin.from("youtube_links")
    .select("channel_id, refresh_token").eq("user_id", user.id).maybeSingle();
  if (!link) return fail("not_linked", "Link your YouTube account first (Settings > Link accounts).");
  const token = await accessToken(link.refresh_token);
  if (!token) {
    await admin.from("youtube_links").delete().eq("user_id", user.id);
    return fail("relink", "Your YouTube link expired. Link your YouTube account again in Settings > Link accounts.");
  }

  const url = String(task.url);
  const busy = (r: { status: number; reason: string }) =>
    r.status === 403 && r.reason.startsWith("quota")
      ? fail("busy", "YouTube is busy right now. Try again in a few minutes.") : null;

  if (task.kind === "subscribe") {
    const target = await channelIdOf(url, token);
    if (!target) return fail("link", "This task needs a channel link like youtube.com/@name or youtube.com/channel/…");
    const r = await yt(`subscriptions?part=id&mine=true&forChannelId=${target}`, token);
    const b = busy(r);
    if (b) return b;
    if (r.status !== 200) return fail("youtube", "Could not check YouTube. Try again in a moment.");
    if (!(r.data.items?.length > 0)) return fail("not_done", "You have not subscribed yet. Subscribe, then tap Verify again.");
  } else {
    const vid = videoIdOf(url);
    if (!vid) return fail("link", "This task needs a video link.");
    if (task.kind === "like") {
      const r = await yt(`videos/getRating?id=${vid}`, token);
      const b = busy(r);
      if (b) return b;
      if (r.status !== 200) return fail("youtube", "Could not check YouTube. Try again in a moment.");
      if (r.data.items?.[0]?.rating !== "like") return fail("not_done", "You have not liked the video yet. Like it, then tap Verify again.");
    } else {
      // comment: look through the newest comments (up to 1000) for one written by this channel
      let found = false, page = "";
      for (let i = 0; i < 10 && !found; i++) {
        const r = await yt(`commentThreads?part=snippet&videoId=${vid}&maxResults=100&order=time${page ? `&pageToken=${page}` : ""}`, token);
        const b = busy(r);
        if (b) return b;
        if (r.reason === "commentsDisabled") return fail("link", "Comments are turned off on this video.");
        if (r.status !== 200) return fail("youtube", "Could not check YouTube. Try again in a moment.");
        for (const it of r.data.items ?? []) {
          if (it.snippet?.topLevelComment?.snippet?.authorChannelId?.value === link.channel_id) { found = true; break; }
        }
        if (!r.data.nextPageToken) break;
        page = r.data.nextPageToken;
      }
      if (!found) return fail("not_done", "We could not find your comment yet. Post it, wait a minute, then tap Verify again.");
    }
  }

  const { data: pts, error } = await admin.rpc("claim_verified_task", { p_user: user.id, p_task: String(task.id) });
  if (error) return fail("claim", error.message);
  return json({ points: pts });
});
