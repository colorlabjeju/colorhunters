// 컬러헌터스 계정 서버 함수 — 아이디+비밀번호 가입, 개인 링크 계정 옮기기, 관리자 비밀번호 초기화
// 아이디는 로그인용 가상 이메일(아이디@id.colorhunters.app)로 저장하고 메일은 보내지 않는다.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
const DOMAIN = "id.colorhunters.app";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const fail = (error: string, status = 400) => out({ error }, status);

const normId = (s: unknown) => String(s ?? "").trim().toLowerCase();
const okId = (s: string) => /^[a-z0-9_]{4,20}$/.test(s);
const okPw = (s: unknown) => typeof s === "string" && s.length >= 6 && s.length <= 72;
const normCode = (s: unknown) => String(s ?? "").replace(/\s/g, "").toLowerCase();
const clip = (s: unknown, n: number) => String(s ?? "").trim().slice(0, n);

async function caller(req: Request) {
  const t = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!t || t.split(".").length !== 3) return null;
  const { data, error } = await admin.auth.getUser(t);
  return error ? null : data.user;
}
async function createLogin(loginId: string, password: string, nickname: string) {
  const { data, error } = await admin.auth.admin.createUser({
    email: `${loginId}@${DOMAIN}`, password, email_confirm: true,
    user_metadata: { login_id: loginId, nickname },
  });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) throw new Error("id_taken");
    if (/password/i.test(error.message)) throw new Error("weak_password");
    throw error;
  }
  return data.user!;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("method", 405);
  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return fail("bad_json"); }
  const action = String(b.action || "");

  try {
    // 1) 참여 코드로 새로 가입
    if (action === "signup") {
      const loginId = normId(b.login_id), nickname = clip(b.nickname, 30);
      if (!okId(loginId)) return fail("bad_id");
      if (!okPw(b.password)) return fail("weak_password");
      if (!nickname) return fail("no_nickname");
      const { data: codes } = await admin.from("edition_codes").select("edition, code, role, active").eq("active", true);
      const hit = (codes || []).find((c) => normCode(c.code) === normCode(b.code));
      if (!hit) return fail("bad_code");
      const { data: taken } = await admin.from("invites").select("token").eq("login_id", loginId).maybeSingle();
      if (taken) return fail("id_taken");
      const user = await createLogin(loginId, b.password as string, nickname);
      try {
        let r = await admin.from("invites").insert({
          edition: hit.edition, role: hit.role, nickname, real_name: clip(b.real_name, 40), phone: clip(b.phone, 30),
          memo: "참여 코드로 가입", user_id: user.id, redeemed_at: new Date().toISOString(), login_id: loginId, created_by: null,
        });
        if (r.error) throw r.error;
        r = await admin.from("user_roles").insert({ user_id: user.id, role: hit.role, edition: hit.edition });
        if (r.error) throw r.error;
        await admin.from("profiles").upsert({ id: user.id, nickname });
      } catch (e) {
        await admin.auth.admin.deleteUser(user.id);
        throw e;
      }
      return out({ ok: true, email: user.email, edition: hit.edition });
    }

    // 2) 개인 링크로 쓰던 사람이 아이디를 만들기 — 기록·역할·동의를 그대로 옮긴다
    if (action === "upgrade") {
      const me = await caller(req);
      if (!me) return fail("sign_in_first", 401);
      const loginId = normId(b.login_id);
      if (!okId(loginId)) return fail("bad_id");
      if (!okPw(b.password)) return fail("weak_password");
      const { data: inv } = await admin.from("invites").select("token, nickname, login_id").eq("user_id", me.id).maybeSingle();
      if (!inv) return fail("no_invite");
      if (inv.login_id) return fail("already_has_id");
      const { data: taken } = await admin.from("invites").select("token").eq("login_id", loginId).maybeSingle();
      if (taken) return fail("id_taken");
      const user = await createLogin(loginId, b.password as string, inv.nickname || "");
      const { data: moved, error } = await admin.rpc("link_resident", { p_old: me.id, p_new: user.id, p_login: loginId });
      if (error) { await admin.auth.admin.deleteUser(user.id); throw error; }
      return out({ ok: true, email: user.email, moved });
    }

    // 3) 관리자: 비밀번호 초기화 (임시 비밀번호 6자리를 돌려줌)
    if (action === "reset") {
      const me = await caller(req);
      if (!me) return fail("sign_in_first", 401);
      const { data: roles } = await admin.from("user_roles").select("role, edition").eq("user_id", me.id);
      if (!(roles || []).some((r) => ["admin", "superadmin"].includes(r.role) && !r.edition)) return fail("not_allowed", 403);
      const { data: inv } = await admin.from("invites").select("user_id, login_id").eq("token", String(b.token || "")).maybeSingle();
      if (!inv || !inv.user_id || !inv.login_id) return fail("no_login");
      const pw = String(crypto.getRandomValues(new Uint32Array(1))[0] % 900000 + 100000);
      const { error } = await admin.auth.admin.updateUserById(inv.user_id, { password: pw });
      if (error) throw error;
      await admin.from("audit_logs").insert({ actor: me.id, action: "password_reset", target: "invites", target_id: inv.login_id });
      return out({ ok: true, password: pw, login_id: inv.login_id });
    }

    return fail("unknown_action");
  } catch (e) {
    const m = (e as Error).message || String(e);
    if (["id_taken", "weak_password"].includes(m)) return fail(m);
    console.error(e);
    return fail("server", 500);
  }
});
