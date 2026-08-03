const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, prefer",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function backendHeaders(serviceKey: string, extra: Record<string, string> = {}) {
  return {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    ...extra,
  };
}

async function backendRequest(
  supabaseUrl: string,
  serviceKey: string,
  path: string,
  init: RequestInit = {},
) {
  const response = await fetch(`${supabaseUrl}${path}`, {
    ...init,
    headers: {
      ...backendHeaders(serviceKey),
      ...(init.headers || {}),
    },
  });
  return {
    ok: response.ok,
    status: response.status,
    data: await readJson(response),
  };
}

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, error: "Use POST" }, 405);

  try {
    console.log("[register-daraja] Request started");
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
    const userResult = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${jwt}`,
      },
    });
    const userData = await readJson(userResult);
    const user = userResult.ok ? userData : null;
    if (!user) {
      return json({
        success: false,
        error: String(userData?.msg || userData?.message || "Please sign in again."),
      }, 401);
    }
    console.log("[register-daraja] User verified");

    const staffResult = await backendRequest(
      supabaseUrl,
      serviceKey,
      `/rest/v1/loan_staff?select=id,business_id,role,is_active&auth_user_id=eq.${encodeURIComponent(String(user.id))}&limit=1`,
    );
    const staff = Array.isArray(staffResult.data) ? staffResult.data[0] : null;
    if (!staffResult.ok) {
      return json({
        success: false,
        error: `Could not verify the PataFix administrator: ${String(staffResult.data?.message || staffResult.status)}`,
      }, 500);
    }
    const roles = String(staff?.role || "").split(",").map((role) => role.trim());
    if (!staff?.is_active || !roles.includes("admin")) {
      return json({ success: false, error: "Only the business admin can register Daraja URLs." }, 403);
    }

    const credentialsResult = await backendRequest(
      supabaseUrl,
      serviceKey,
      `/rest/v1/patafix_daraja_credentials?select=consumer_key,consumer_secret&business_id=eq.${encodeURIComponent(String(staff.business_id))}&limit=1`,
    );
    const savedCredentials = Array.isArray(credentialsResult.data) ? credentialsResult.data[0] : null;
    if (!credentialsResult.ok) {
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
    console.log(`[register-daraja] OAuth accepted for ${sandbox ? "sandbox" : "production"}`);

    const validationUrl = `${supabaseUrl}/functions/v1/patafix-c2b-validation`;
    const confirmationUrl = `${supabaseUrl}/functions/v1/patafix-payment-callback`;

    // The PataFix production app is provisioned for C2B v2. Do not hide a v2
    // provisioning or shortcode error behind an unrelated v1 fallback error.
    let registration = await registerUrls(
      url,
      sandbox ? "v1" : "v2",
      tokenResult.token,
      cleanShortcode,
      validationUrl,
      confirmationUrl,
    );

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
          ? `Safaricom rejected the access token for C2B ${registration.version}. Confirm that the Consumer Key and Consumer Secret belong to the same ${sandbox ? "sandbox" : "production"} app and that C2B ${registration.version} access is approved on that app.`
          : registration.message || `Daraja URL registration failed using C2B ${registration.version}`,
        response: registration.data,
        c2b_version: registration.version,
        daraja_environment: sandbox ? "sandbox" : "production",
        validation_url: validationUrl,
        confirmation_url: confirmationUrl,
      }, 400);
    }
    console.log(`[register-daraja] C2B ${registration.version} URLs accepted`);

    if (suppliedKey && suppliedSecret) {
      const saveCredentialsResult = await backendRequest(
        supabaseUrl,
        serviceKey,
        "/rest/v1/patafix_daraja_credentials?on_conflict=business_id",
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Prefer: "resolution=merge-duplicates,return=minimal",
          },
          body: JSON.stringify({
          business_id: staff.business_id,
          consumer_key: suppliedKey,
          consumer_secret: suppliedSecret,
          updated_by: staff.id,
          updated_at: new Date().toISOString(),
          }),
        },
      );
      if (!saveCredentialsResult.ok) {
        return json({
          success: false,
          error: "Safaricom accepted the URLs, but PataFix could not save the credentials securely. " + String(saveCredentialsResult.data?.message || saveCredentialsResult.status),
        }, 500);
      }
    }

    const settingsResult = await backendRequest(
      supabaseUrl,
      serviceKey,
      `/rest/v1/loan_settings?business_id=eq.${encodeURIComponent(String(staff.business_id))}`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json", Prefer: "return=minimal" },
        body: JSON.stringify({
        mpesa_shortcode: cleanShortcode,
        daraja_environment: String(environment || "sandbox").toLowerCase().includes("sandbox") ? "sandbox" : "production",
        daraja_credentials_saved: Boolean(suppliedKey && suppliedSecret) || Boolean(savedCredentials?.consumer_key),
        }),
      },
    );
    if (!settingsResult.ok) {
      return json({ success: false, error: "Daraja was registered, but its saved status could not be updated. " + String(settingsResult.data?.message || settingsResult.status) }, 500);
    }

    return json({
      success: true,
      warning: registration.alreadyRegistered ? registration.message : undefined,
      data: registration.data,
      c2b_version: registration.version,
      validation_url: validationUrl,
      confirmation_url: confirmationUrl,
      credentials_saved: Boolean(suppliedKey && suppliedSecret) || Boolean(savedCredentials?.consumer_key),
    });
  } catch (error) {
    return json({ success: false, error: error instanceof Error ? error.message : String(error) }, 500);
  }
});
