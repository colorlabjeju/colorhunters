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

// 색·짚은 곳은 올린 사람이 보낸 값이라, 모양이 맞는 것만 골라 내보낸다
const HEX = /^#[0-9A-Fa-f]{6}$/;
const ROLES = new Set(["main", "accent", "sub"]);
const unit = (v: unknown) => (typeof v === "number" && v >= 0 && v <= 1 ? v : null);
const xy = (o: any) => (o && unit(o.x) != null && unit(o.y) != null ? { x: o.x, y: o.y } : null);
function colorsOf(c: any) {
  const list = Array.isArray(c?.colors) ? c.colors.filter((x: any) => HEX.test(x?.hex ?? "")).slice(0, 3) : [];
  if (!list.length) return null;
  const at = xy(c.roi);
  return {
    calibrated: c.calibrated === true,
    // role: main(내가 본 색) · accent(포인트 색) · sub(함께 보인 색). 없거나 모르는 값이면 순서로 정한다
    colors: list.map((x: any, i: number) => ({ hex: x.hex.toUpperCase(), share: unit(x.share), role: ROLES.has(x.role) ? x.role : (i ? "sub" : "main") })),
    roi: at ? { ...at, photo: c.roi.photo === 2 ? 2 : 1, r: unit(c.roi.r) ?? 0.24 } : null,
  };
}

// 찍은 때 이름표 — 해 높이(NOAA 근사식). 화면(index.html)의 sunPos·sunLabel과 같은 계산
const SUN_CENTER: Record<string, [number, number]> = { ulleung: [37.505, 130.865] };
function sunLabel(iso: string, lat: number, lng: number): string {
  const t = new Date(iso);
  if (isNaN(t.getTime())) return "";
  const rad = Math.PI / 180, y = t.getUTCFullYear(), leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const doy = Math.floor((Date.UTC(y, t.getUTCMonth(), t.getUTCDate()) - Date.UTC(y, 0, 0)) / 864e5);
  const hr = t.getUTCHours() + t.getUTCMinutes() / 60 + t.getUTCSeconds() / 3600;
  const g = (2 * Math.PI / (leap ? 366 : 365)) * (doy - 1 + (hr - 12) / 24);
  const eq = 229.18 * (0.000075 + 0.001868 * Math.cos(g) - 0.032077 * Math.sin(g) - 0.014615 * Math.cos(2 * g) - 0.040849 * Math.sin(2 * g));
  const dec = 0.006918 - 0.399912 * Math.cos(g) + 0.070257 * Math.sin(g) - 0.006758 * Math.cos(2 * g) + 0.000907 * Math.sin(2 * g) - 0.002697 * Math.cos(3 * g) + 0.00148 * Math.sin(3 * g);
  let tst = (hr * 60 + eq + 4 * lng) % 1440;
  if (tst < 0) tst += 1440;
  const cz = Math.sin(lat * rad) * Math.sin(dec) + Math.cos(lat * rad) * Math.cos(dec) * Math.cos((tst / 4 - 180) * rad);
  const e = 90 - Math.acos(Math.max(-1, Math.min(1, cz))) / rad, m = tst - 720;
  if (e < -6) return "밤";
  if (Math.abs(m) <= 60 && e > 0) return "한낮";
  if (m < 0) return e < 0 ? "새벽" : e < 15 ? "아침" : "오전";
  return e >= 15 ? "오후" : "해 질 녘";
}
// 새 기록은 저장된 이름표(light). 예전 기록(taken_src 없음)은 사진에 찍은 시각이 있었을 때만 계산해 보여 준다
function todOf(r: Record<string, any>, edition: string): string {
  if (r.is_memory) return "";
  if (r.taken_src) return r.taken_src === "unknown" ? "" : (r.light || "");
  const c = SUN_CENTER[edition];
  if (!c || !r.taken_at || !(r.d1 || r.d2)) return r.light || "";
  return sunLabel(r.taken_at, r.lat ?? c[0], r.lng ?? c[1]) || r.light || "";
}

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
  // 나눠 받기: limit(1~100)·offset. limit이 없으면 예전 화면처럼 한 번에 300건까지. category로 분류 하나만 고를 수 있다
  const int = (k: string) => { const v = url.searchParams.get(k); return v != null && /^\d{1,6}$/.test(v) ? parseInt(v, 10) : null; };
  const limit = int("limit") != null ? Math.min(100, Math.max(1, int("limit")!)) : 300;
  const offset = int("offset") ?? 0;
  const category = (url.searchParams.get("category") ?? "").slice(0, 40);

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

  // 보여 줄 수 있는 기록의 조건 (건수 세기와 목록에 똑같이 쓴다)
  const scoped = (q: any) => {
    q = q.eq("edition", edition).eq("share", true);
    return group ? q.in("status", ["pending", "held", "approved"]) : q.eq("status", "approved").eq("public_pick", true);
  };
  // 전체 건수와 분류별 건수 — 분류 칩에 쓴다 (사진 서명 없이 분류 칸만 읽는다)
  const { data: cats, error: cErr } = await scoped(sb.from("records").select("category")).limit(5000);
  if (cErr) return json({ error: "load failed" }, 500);
  const counts: Record<string, number> = {};
  (cats ?? []).forEach((c: any) => { counts[c.category] = (counts[c.category] ?? 0) + 1; });
  const total = (cats ?? []).length;

  let q = scoped(sb
    .from("records")
    .select("id,author,status,category,local_name,color_name,usage,story,keyring,area,is_memory,photo1_path,photo2_path,photo1_preview,photo2_preview,created_at,lat,lng,colors,target_xy,light,taken_at,taken_src,time_note,d1:exif1->>DateTimeOriginal,d2:exif2->>DateTimeOriginal"));
  if (category) q = q.eq("category", category);
  const { data, error } = await q.order("created_at", { ascending: false }).order("id").range(offset, offset + limit - 1);
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
  const paths = [...new Set(rows.flatMap((r: any) => photosOf(r).map((x) => x.path)))] as string[];
  const signed: Record<string, string> = {};
  if (paths.length) {
    const { data: s } = await sb.storage.from("record-photos").createSignedUrls(paths, 60 * 60 * 6);
    (s ?? []).forEach((x) => { if (x.path && x.signedUrl) signed[x.path] = x.signedUrl; });
  }
  // 기여자 별칭: 공개 에디션 참여 별칭 우선, 없으면 초대 별칭
  const authors = [...new Set(rows.map((r: any) => r.author))];
  const nick: Record<string, string> = {};
  if (authors.length) {
    const { data: inv } = await sb.from("invites").select("user_id,nickname").in("user_id", authors);
    (inv ?? []).forEach((i) => { if (i.user_id) nick[i.user_id] = i.nickname; });
    const { data: par } = await sb.from("participations").select("user_id,nickname").eq("edition", edition).in("user_id", authors);
    (par ?? []).forEach((p) => { if (p.user_id) nick[p.user_id] = p.nickname; });
  }

  const out = rows.map((r: Record<string, any>) => {
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
      // 뽑은 색(보정 전 표시 포함)과, 정사각 카드로 자를 때 기준이 되는 짚은 곳
      colors: colorsOf(r.colors),
      focus: xy(r.target_xy) ?? xy(r.colors?.roi),
      // 찍은 때: 이름표와 «그때를 내 말로»만 (정확한 시각은 내보내지 않는다)
      tod: todOf(r, edition),
      time_note: r.time_note || "",
      by: nick[r.author] ?? "",
      at: r.created_at,
      // 좌표: 민감 분류는 없음, 나머지는 약 100m 단위로 뭉갬
      lat: hide ? null : Math.round(r.lat * 1000) / 1000,
      lng: hide ? null : Math.round(r.lng * 1000) / 1000,
    };
  });
  return json({ edition, scope: group ? "group" : "public", count: out.length, total, counts, offset, limit, records: out }, 200, {
    "Cache-Control": group ? "private, no-store" : "public, max-age=120",
  });
});
