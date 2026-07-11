// Edge function invoked by the phone companion web app after it finishes
// OAuth against MyAnimeList, AniList, or Kitsu. The phone posts the tokens
// here; this function stashes them into the TV's pending session row so the
// TV's next `poll_tracker_tv_login_session` returns them.
//
// Contract:
//   POST /functions/v1/tracker-tv-logins-exchange
//   Headers:
//     Authorization: Bearer <phone's Supabase user JWT>
//     Content-Type: application/json
//   Body:
//     {
//       code: string,                         // session code from the QR
//       tracker: "mal" | "anilist" | "kitsu",
//       access_token: string,
//       refresh_token?: string,
//       expires_in?: number,                  // seconds from now
//       tracker_user_id?: string,
//       username?: string
//     }
//
// Auth: the phone must already be signed into the same Supabase project as
// the NuvioTV app. We verify that the authenticated user id matches the
// session's `owner_user_id` so a different user can't hijack someone else's
// pending login.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";

const CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type ExchangeBody = {
    code?: unknown;
    tracker?: unknown;
    access_token?: unknown;
    refresh_token?: unknown;
    expires_in?: unknown;
    tracker_user_id?: unknown;
    username?: unknown;
};

serve(async (req) => {
    if (req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (req.method !== "POST") {
        return json({ error: "method_not_allowed" }, 405);
    }

    const auth = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
    if (!auth) return json({ error: "unauthorized" }, 401);

    let body: ExchangeBody;
    try {
        body = await req.json();
    } catch (_) {
        return json({ error: "bad_json" }, 400);
    }

    const code = asString(body.code);
    const tracker = asString(body.tracker);
    const accessToken = asString(body.access_token);
    const refreshToken = asStringOrNull(body.refresh_token);
    const expiresIn = asNumberOrNull(body.expires_in);
    const trackerUserId = asStringOrNull(body.tracker_user_id);
    const username = asStringOrNull(body.username);

    if (!code || !tracker || !accessToken) {
        return json({ error: "missing_required_field" }, 400);
    }
    if (tracker !== "mal" && tracker !== "anilist" && tracker !== "kitsu") {
        return json({ error: "bad_tracker" }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceKey) {
        return json({ error: "server_misconfigured" }, 500);
    }

    // Phone-authenticated client — lets us resolve auth.uid() for the caller.
    const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: `Bearer ${auth}` } },
    });
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) return json({ error: "unauthorized" }, 401);

    // Service-role client — bypasses RLS on the sessions table (only insert
    // happens via SECURITY DEFINER RPCs; updates need service role since
    // there's no UPDATE policy).
    const admin = createClient(supabaseUrl, serviceKey, {
        auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: sess, error: selErr } = await admin
        .from("tracker_tv_login_sessions")
        .select("*")
        .eq("code", code)
        .eq("tracker", tracker)
        .maybeSingle();
    if (selErr) return json({ error: "lookup_failed", detail: selErr.message }, 500);
    if (!sess) return json({ error: "session_not_found" }, 404);

    if (new Date(sess.expires_at) < new Date()) {
        await admin.from("tracker_tv_login_sessions").delete().eq("code", code);
        return json({ error: "session_expired" }, 410);
    }
    if (sess.owner_user_id !== userData.user.id) {
        return json({ error: "owner_mismatch" }, 403);
    }

    const { error: updErr } = await admin
        .from("tracker_tv_login_sessions")
        .update({
            status: "ready",
            access_token: accessToken,
            refresh_token: refreshToken,
            expires_in: expiresIn,
            tracker_user_id: trackerUserId,
            tracker_username: username,
        })
        .eq("code", code);
    if (updErr) return json({ error: "update_failed", detail: updErr.message }, 500);

    return json({ ok: true });
});

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json", ...CORS_HEADERS },
    });
}

function asString(v: unknown): string | null {
    return typeof v === "string" && v.length > 0 ? v : null;
}

function asStringOrNull(v: unknown): string | null {
    if (v === null || v === undefined) return null;
    return typeof v === "string" && v.length > 0 ? v : null;
}

function asNumberOrNull(v: unknown): number | null {
    if (v === null || v === undefined) return null;
    return typeof v === "number" && Number.isFinite(v) ? v : null;
}
