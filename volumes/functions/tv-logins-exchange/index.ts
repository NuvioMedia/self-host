// supabase/functions/tv-login-exchange/index.ts
import "jsr:@supabase/functions-js@2.108.2/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface ExchangeBody {
  code: string;
  device_nonce: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = (await req.json()) as ExchangeBody;
    if (!body?.code || !body?.device_nonce) {
      return new Response(JSON.stringify({ error: "code and device_nonce are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Atomically consume approved login session
    const { data: consumed, error: consumeErr } = await admin.rpc("consume_tv_login_session", {
      p_code: body.code,
      p_device_nonce: body.device_nonce,
    });

    if (consumeErr) {
      return new Response(JSON.stringify({ error: consumeErr.message }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const row = Array.isArray(consumed) ? consumed[0] : consumed;
    const approvedUserId = row?.approved_user_id as string | undefined;
    if (!approvedUserId) {
      return new Response(JSON.stringify({ error: "No approved user found" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Get approved user email
    const { data: userRes, error: userErr } = await admin.auth.admin.getUserById(approvedUserId);
    if (userErr || !userRes?.user?.email) {
      return new Response(JSON.stringify({ error: "Approved user email not found" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Generate one-time magic link token (no email sent)
    const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: userRes.user.email,
      options: { redirectTo: "https://example.com/ignore" },
    });

    if (linkErr) {
      return new Response(JSON.stringify({ error: linkErr.message }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // token_hash is preferred; fallback parse from action_link
    const tokenHash =
      (linkData as any)?.properties?.hashed_token ||
      new URL((linkData as any)?.properties?.action_link).searchParams.get("token_hash");

    if (!tokenHash) {
      return new Response(JSON.stringify({ error: "Failed to create token hash" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Exchange token_hash for real access/refresh session
    const publicClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { data: verifyData, error: verifyErr } = await publicClient.auth.verifyOtp({
      type: "magiclink",
      token_hash: tokenHash,
    });

    if (verifyErr || !verifyData?.session) {
      return new Response(JSON.stringify({ error: verifyErr?.message || "Session exchange failed" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({
        access_token: verifyData.session.access_token,
        refresh_token: verifyData.session.refresh_token,
        token_type: verifyData.session.token_type,
        expires_in: verifyData.session.expires_in,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
