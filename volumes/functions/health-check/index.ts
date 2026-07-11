import "jsr:@supabase/functions-js@2.108.2/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const start = Date.now();

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Lightweight DB ping
    const { data, error } = await supabase.rpc("health_ping").maybeSingle();

    const latencyMs = Date.now() - start;

    if (error) {
      // DB is reachable but query failed — degraded
      return new Response(
        JSON.stringify({
          status: "degraded",
          database: "error",
          error: error.message,
          latency_ms: latencyMs,
          timestamp: new Date().toISOString(),
        }),
        {
          status: 503,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    return new Response(
      JSON.stringify({
        status: latencyMs < 3000 ? "healthy" : "slow",
        database: "connected",
        latency_ms: latencyMs,
        timestamp: new Date().toISOString(),
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    const latencyMs = Date.now() - start;
    return new Response(
      JSON.stringify({
        status: "down",
        database: "unreachable",
        error: err.message,
        latency_ms: latencyMs,
        timestamp: new Date().toISOString(),
      }),
      {
        status: 503,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
