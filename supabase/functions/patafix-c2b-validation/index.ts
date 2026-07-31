import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function response(resultCode: number, resultDesc: string) {
  return new Response(JSON.stringify({ ResultCode: resultCode, ResultDesc: resultDesc }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response(0, "Accepted");

  try {
    // Validation must stay fast and must never create a repayment.
    await req.json().catch(() => null);
    return response(0, "Accepted");
  } catch (error) {
    console.error("PataFix C2B validation error:", error);
    return response(0, "Accepted");
  }
});
