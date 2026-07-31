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

async function getAccessToken(base: string, consumerKey: string, consumerSecret: string) {
  const response = await fetch(`${base}/oauth/v1/generate?grant_type=client_credentials`, {
    headers: { Authorization: `Basic ${btoa(`${consumerKey}:${consumerSecret}`)}` },
  });
  const data = await readJson(response);
  return {
    ok: response.ok && Boolean(data.access_token),
    token: String(data.access_token || "").trim(),
    data,
    status: response.status,
  };
}

function isInvalidAccessToken(result: { status: number; message: string }) {
  const message = String(result.message || "").toLowerCase();
  return result.status === 401 || message.includes("invalid access token");
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
    const { shortcode, environment, consumer_key, consumer_secret } = await req.json();
    const cleanShortcode = String(shortcode || "").trim();
    const suppliedKey = String(consumer_key || "").trim();
    const suppliedSecret = String(consumer_secret || "").trim();

    if (!cleanShortcode) {
      return json({ success: false, error: "Missing Daraja Paybill shortcode" }, 400);
    }
    if (Boolean(suppliedKey) !== Boolean(suppliedSecret)) {
      return json({
        success: false,
        error: "Enter both the Daraja Consumer Key and Consumer Secret.",
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
      .select("id, business_id, role, is_active")
      .eq("auth_user_id", user.id)
      .maybeSingle();
    const roles = String(staff?.role || "").split(",").map((role) => role.trim());
    if (!staff?.is_active || !roles.includes("admin")) {
      return json({ success: false, error: "Only the business admin can register Daraja URLs." }, 403);
    }

    const { data: savedCredentials, error: credentialsError } = await supabase
      .from("patafix_daraja_credentials")
      .select("consumer_key, consumer_secret")
      .eq("business_id", staff.business_id)
      .maybeSingle();
    if (credentialsError && credentialsError.code !== "PGRST116") {
      return json({
        success: false,
        error: "The secure Daraja credential store is not ready. Run patafix-daraja-secure-credentials.sql in Supabase, then redeploy this function.",
      }, 500);
    }

    const cleanKey = suppliedKey || String(savedCredentials?.consumer_key || Deno.env.get("PATAFIX_DARAJA_CONSUMER_KEY") || "").trim();
    const cleanSecret = suppliedSecret || String(savedCredentials?.consumer_secret || Deno.env.get("PATAFIX_DARAJA_CONSUMER_SECRET") || "").trim();
    if (!cleanKey || !cleanSecret) {
      return json({
        success: false,
        error: "Daraja credentials are missing. Enter the Consumer Key and Consumer Secret in Settings, then save again.",
      }, 400);
    }

    const url = baseUrl(environment);
    const sandbox = String(environment || "").toLowerCase().includes("sandbox");
    let tokenResult = await getAccessToken(url, cleanKey, cleanSecret);
    if (!tokenResult.ok) {
      return json({
        success: false,
        error: tokenResult.data.errorMessage || tokenResult.data.error_description || "Failed to authenticate with Daraja",
        response: tokenResult.data,
      }, 400);
    }

    const validationUrl = `${supabaseUrl}/functions/v1/patafix-c2b-validation`;
    const confirmationUrl = `${supabaseUrl}/functions/v1/patafix-payment-callback`;

    // Safaricom sandbox is most reliable on C2B v1. Production prefers v2.
    let registration = await registerUrls(
      url,
      sandbox ? "v1" : "v2",
      tokenResult.token,
      cleanShortcode,
      validationUrl,
      confirmationUrl,
    );
    let v2Failure = null;
    if (!sandbox && !registration.ok) {
      v2Failure = {
        status: registration.status,
        message: registration.message,
        response: registration.data,
      };
      tokenResult = await getAccessToken(url, cleanKey, cleanSecret);
      if (!tokenResult.ok) {
        return json({
          success: false,
          error: "Daraja OAuth refresh failed before the C2B v1 fallback.",
          response: tokenResult.data,
          v2_failure: v2Failure,
        }, 400);
      }
      registration = await registerUrls(
        url,
        "v1",
        tokenResult.token,
        cleanShortcode,
        validationUrl,
        confirmationUrl,
      );
    }

    if (sandbox && !registration.ok && isInvalidAccessToken(registration)) {
      tokenResult = await getAccessToken(url, cleanKey, cleanSecret);
      if (tokenResult.ok) {
        registration = await registerUrls(
          url,
          "v1",
          tokenResult.token,
          cleanShortcode,
          validationUrl,
          confirmationUrl,
        );
      }
    }

    if (!registration.ok) {
      const invalidToken = isInvalidAccessToken(registration);
      return json({
        success: false,
        error: invalidToken
          ? `Safaricom rejected the access token for C2B ${registration.version}. Confirm that the Consumer Key and Consumer Secret belong to the same ${sandbox ? "sandbox" : "production"} app and that C2B API access is enabled on that app.`
          : registration.message || `Daraja URL registration failed using C2B ${registration.version}`,
        response: registration.data,
        v2_failure: v2Failure,
        validation_url: validationUrl,
        confirmation_url: confirmationUrl,
      }, 400);
    }

    if (suppliedKey && suppliedSecret) {
      const { error: saveCredentialsError } = await supabase
        .from("patafix_daraja_credentials")
        .upsert({
          business_id: staff.business_id,
          consumer_key: suppliedKey,
          consumer_secret: suppliedSecret,
          updated_by: staff.id,
          updated_at: new Date().toISOString(),
        }, { onConflict: "business_id" });
      if (saveCredentialsError) {
        return json({
          success: false,
          error: "Safaricom accepted the URLs, but PataFix could not save the credentials securely. " + saveCredentialsError.message,
        }, 500);
      }
    }

    const { error: settingsError } = await supabase
      .from("loan_settings")
      .update({
        mpesa_shortcode: cleanShortcode,
        daraja_environment: String(environment || "sandbox").toLowerCase().includes("sandbox") ? "sandbox" : "production",
        daraja_credentials_saved: Boolean(suppliedKey && suppliedSecret) || Boolean(savedCredentials?.consumer_key),
      })
      .eq("business_id", staff.business_id);
    if (settingsError) {
      return json({ success: false, error: "Daraja was registered, but its saved status could not be updated. " + settingsError.message }, 500);
    }

    return json({
      success: true,
      warning: registration.alreadyRegistered ? registration.message : undefined,
      data: registration.data,
      c2b_version: registration.version,
      validation_url: validationUrl,
      confirmation_url: confirmationUrl,
      credentials_saved: Boolean(suppliedKey && suppliedSecret) || Boolean(savedCredentials?.consumer_key),
      v2_failure: registration.version === "v1" ? v2Failure : undefined,
    });
  } catch (error) {
    return json({ success: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
