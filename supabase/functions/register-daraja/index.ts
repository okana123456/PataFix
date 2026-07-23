import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, prefer",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function baseUrl(environment: string) {
  return String(environment || "").toLowerCase().includes("sandbox")
    ? "https://sandbox.safaricom.co.ke"
    : "https://api.safaricom.co.ke";
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, error: "Use POST" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    const { shortcode, consumer_key, consumer_secret, environment } = await req.json();
    const cleanShortcode = String(shortcode || "").trim();
    const cleanKey = String(consumer_key || "").trim();
    const cleanSecret = String(consumer_secret || "").trim();

    if (!cleanShortcode || !cleanKey || !cleanSecret) {
      return json({ success: false, error: "Missing Daraja credentials" }, 400);
    }

    const supabaseUrl = Deno.env.get("PATAFIX_PROJECT_URL") || "";
    const serviceKey = Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "";
    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData } = await supabase.auth.getUser(jwt);
    const user = userData?.user;
    if (!user) return json({ success: false, error: "Please sign in again." }, 401);

    const { data: staff } = await supabase
      .from("loan_staff")
      .select("id, role, is_active")
      .eq("auth_user_id", user.id)
      .maybeSingle();
    if (!staff?.is_active || staff.role !== "admin") {
      return json({ success: false, error: "Only the business admin can register Daraja URLs." }, 403);
    }

    const url = baseUrl(environment);
    const tokenResponse = await fetch(`${url}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${cleanKey}:${cleanSecret}`)}` },
    });
    const tokenData = await tokenResponse.json();
    if (!tokenResponse.ok || !tokenData.access_token) {
      return json({
        success: false,
        error: tokenData.errorMessage || tokenData.error_description || "Failed to authenticate with Daraja",
        response: tokenData,
      }, 400);
    }

    const confirmationUrl = `${supabaseUrl}/functions/v1/patafix-payment-callback`;
    const registerResponse = await fetch(`${url}/mpesa/c2b/v2/registerurl`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${tokenData.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        ShortCode: cleanShortcode,
        ResponseType: "Completed",
        ConfirmationURL: confirmationUrl,
        ValidationURL: confirmationUrl,
      }),
    });

    const registerData = await registerResponse.json();
    if (!registerResponse.ok || registerData.errorMessage) {
      const message = String(registerData.errorMessage || registerData.ResponseDescription || "");
      if (message.toLowerCase().includes("already registered")) {
        return json({
          success: true,
          warning: message,
          data: registerData,
          confirmation_url: confirmationUrl,
        });
      }
      return json({
        success: false,
        error: message || "Daraja URL registration failed",
        response: registerData,
      }, 400);
    }

    return json({ success: true, data: registerData, confirmation_url: confirmationUrl });
  } catch (error) {
    return json({ success: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
