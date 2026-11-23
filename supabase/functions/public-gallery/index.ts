import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// 모인 기록 — 보는 사람에 따라 두 단계로 내보낸다.
//  · 바깥(누구나): 인정 + 공개 동의 + 운영진이 «공개 선정»한 기록만.
//  · 수집단 안(아이디로 로그인한 같은 미션 주민·운영진): 올리는 즉시 모두(확인 중·보완 요청·인정, 반려 제외).
//    공개 동의를 끈 기록은 수집단 안에서도 내보내지 않는다. 확인 전 기록은 작은 미리보기 사진만.
// 어느 쪽이든 필요한 칸만 내보내고, 원본 좌표·EXIF·작성자 정보는 내보내지 않는다.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
// 채취지가 드러나면 안 되는 분류: 동네 이름만 (수집단 안에서도 똑같이)
const HIDE_COORDS = new Set(["나물·약초", "식물·꽃·열매", "기억 카드"]);

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8", ...extra },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "GET") return json({ error: "method not allowed" }, 405);
  const url = new URL(req.url);
  const edition = url.searchParams.get("edition") ?? "";
  if (!/^[a-z][a-z0-9]{1,23}$/.test(edition)) return json({ error: "bad edition" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  // 수집단원인지: 아이디로 로그인(익명 아님)했고 이 미션의 역할이 있거나 전체 관리자
  let group = false;
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (token && token !== Deno.env.get("SUPABASE_ANON_KEY")) {
    const { data: u } = await sb.auth.getUser(token);
    const user = u?.user;
    if (user && !user.is_anonymous) {
      const { data: roles } = await sb.from("user_roles").select("role,edition").eq("user_id", user.id);
      group = (roles ?? []).some((r) => r.edition === edition || (r.edition == null && (r.role === "admin" || r.role === "superadmin")));
    }
  }

  let q = sb
    .from("records")
    .select("id,author,status,category,local_name,color_name,usage,story,keyring,area,is_memory,photo1_path,photo2_path,photo1_preview,photo2_preview,created_at,lat,lng")
    .eq("edition", edition)
    .eq("share", true);
  q = group ? q.in("status", ["pending", "held", "approved"]) : q.eq("status", "approved").eq("public_pick", true);
  const { data, error } = await q.order("created_at", { ascending: false }).limit(300);
  if (error) return json({ error: "load failed" }, 500);
  const rows = data ?? [];

  // 사진: 키링 없이 찍은 장면 사진을 우선, 없으면 키링 사진. 확인 전(인정 아님) 기록은 작은 미리보기를 쓴다.
  // 미리보기를 만들기 전에 올라온 예전 기록은 미리보기가 없으므로 원래 사진으로 대신한다.
  const pathOf = (r: Record<string, any>, n: 1 | 2) =>
    (r.status === "approved" ? r[`photo${n}_path`] : r[`photo${n}_preview`] || r[`photo${n}_path`]) || null;
  // 넘겨 볼 사진 두 장: ② 키링 없이(장면) 먼저, 그다음 ① 키링과 함께
  const photosOf = (r: Record<string, any>) =>
    ([[2, "scene"], [1, "keyring"]] as const)
      .map(([n, kind]) => ({ kind, path: pathOf(r, n) }))
      .filter((x) => x.path) as { kind: string; path: string }[];
  const paths = [...new Set(rows.flatMap((r) => photosOf(r).map((x) => x.path)))] as string[];
  const signed: Record<string, string> = {};
  if (paths.length) {
    const { data: s } = await sb.storage.from("record-photos").createSignedUrls(paths, 60 * 60 * 6);
    (s ?? []).forEach((x) => { if (x.path && x.signedUrl) signed[x.path] = x.signedUrl; });
  }
  // 기여자 별칭: 공개 에디션 참여 별칭 우선, 없으면 초대 별칭
  const authors = [...new Set(rows.map((r) => r.author))];
  const nick: Record<string, string> = {};
  if (authors.length) {
    const { data: inv } = await sb.from("invites").select("user_id,nickname").in("user_id", authors);
    (inv ?? []).forEach((i) => { if (i.user_id) nick[i.user_id] = i.nickname; });
    const { data: par } = await sb.from("participations").select("user_id,nickname").eq("edition", edition).in("user_id", authors);
    (par ?? []).forEach((p) => { if (p.user_id) nick[p.user_id] = p.nickname; });
  }

  const out = rows.map((r) => {
    const hide = HIDE_COORDS.has(r.category) || r.lat == null;
    const ph = photosOf(r).map((x) => ({ kind: x.kind, url: signed[x.path] ?? null })).filter((x) => x.url);
    return {
      id: r.id,
      ...(group ? { status: r.status } : {}),
      category: r.category,
      name: r.local_name || r.color_name,
      usage: r.usage,
      story: r.story,
      keyring: r.keyring,
      area: r.area,
      is_memory: r.is_memory,
      photo: ph[0]?.url ?? null,
      photos: ph,
      by: nick[r.author] ?? "",
      at: r.created_at,
      // 좌표: 민감 분류는 없음, 나머지는 약 100m 단위로 뭉갬
      lat: hide ? null : Math.round(r.lat * 1000) / 1000,
      lng: hide ? null : Math.round(r.lng * 1000) / 1000,
    };
  });
  return json({ edition, scope: group ? "group" : "public", count: out.length, records: out }, 200, {
    "Cache-Control": group ? "private, no-store" : "public, max-age=120",
  });
});
