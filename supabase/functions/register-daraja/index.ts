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

async function readJson(response: Response): Promise<Record<string, any>> {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return { raw_response: text };
  }
}

async function registerUrls(
  base: string,
  version: "v1" | "v2",
  accessToken: string,
  shortcode: string,
  validationUrl: string,
  confirmationUrl: string,
) {
  const response = await fetch(`${base}/mpesa/c2b/${version}/registerurl`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      ShortCode: shortcode,
      ResponseType: "Completed",
      ConfirmationURL: confirmationUrl,
      ValidationURL: validationUrl,
    }),
  });
  const data = await readJson(response);
  const message = String(
    data?.errorMessage ||
    data?.ResponseDescription ||
    data?.responseDesc ||
    data?.raw_response ||
    "",
  );
  const alreadyRegistered = message.toLowerCase().includes("already registered");
  return {
    ok: (response.ok && !data?.errorMessage) || alreadyRegistered,
    alreadyRegistered,
    message,
    data,
    status: response.status,
    version,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, error: "Use POST" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    const { shortcode, environment } = await req.json();
    const cleanShortcode = String(shortcode || "").trim();
    const cleanKey = String(Deno.env.get("PATAFIX_DARAJA_CONSUMER_KEY") || "").trim();
    const cleanSecret = String(Deno.env.get("PATAFIX_DARAJA_CONSUMER_SECRET") || "").trim();

    if (!cleanShortcode) {
      return json({ success: false, error: "Missing Daraja Paybill shortcode" }, 400);
    }
    if (!cleanKey || !cleanSecret) {
      return json({
        success: false,
        error: "Daraja credentials are missing. Add PATAFIX_DARAJA_CONSUMER_KEY and PATAFIX_DARAJA_CONSUMER_SECRET in Supabase Edge Function secrets.",
      }, 400);
    }

    const supabaseUrl = Deno.env.get("PATAFIX_PROJECT_URL") || "";
    const serviceKey = Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "";
    if (!supabaseUrl || !serviceKey) {
      return json({
        success: false,
        error: "PataFix Supabase secrets are missing. Add PATAFIX_PROJECT_URL and PATAFIX_SERVICE_ROLE_KEY.",
      }, 400);
    }
    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData, error: userError } = await supabase.auth.getUser(jwt);
    const user = userData?.user;
    if (!user) {
      return json({
        success: false,
        error: userError?.message || "Please sign in again.",
      }, 401);
    }

    const { data: staff } = await supabase
      .from("loan_staff")
      .select("id, role, is_active")
      .eq("auth_user_id", user.id)
      .maybeSingle();
    const roles = String(staff?.role || "").split(",").map((role) => role.trim());
    if (!staff?.is_active || !roles.includes("admin")) {
      return json({ success: false, error: "Only the business admin can register Daraja URLs." }, 403);
    }

    const url = baseUrl(environment);
    const tokenResponse = await fetch(`${url}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${cleanKey}:${cleanSecret}`)}` },
    });
    const tokenData = await readJson(tokenResponse);
    if (!tokenResponse.ok || !tokenData.access_token) {
      return json({
        success: false,
        error: tokenData.errorMessage || tokenData.error_description || "Failed to authenticate with Daraja",
        response: tokenData,
      }, 400);
    }

    const validationUrl = `${supabaseUrl}/functions/v1/patafix-c2b-validation`;
    const confirmationUrl = `${supabaseUrl}/functions/v1/patafix-payment-callback`;

    let registration = await registerUrls(
      url,
      "v2",
      tokenData.access_token,
      cleanShortcode,
      validationUrl,
      confirmationUrl,
    );
    let v2Failure = null;
    if (!registration.ok) {
      v2Failure = {
        status: registration.status,
        message: registration.message,
        response: registration.data,
      };
      registration = await registerUrls(
        url,
        "v1",
        tokenData.access_token,
        cleanShortcode,
        validationUrl,
        confirmationUrl,
      );
    }

    if (!registration.ok) {
      return json({
        success: false,
        error: registration.message || "Daraja URL registration failed using C2B v2 and v1",
        response: registration.data,
        v2_failure: v2Failure,
        validation_url: validationUrl,
        confirmation_url: confirmationUrl,
      }, 400);
    }

    return json({
      success: true,
      warning: registration.alreadyRegistered ? registration.message : undefined,
      data: registration.data,
      c2b_version: registration.version,
      validation_url: validationUrl,
      confirmation_url: confirmationUrl,
      v2_failure: registration.version === "v1" ? v2Failure : undefined,
    });
  } catch (error) {
    return json({ success: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
