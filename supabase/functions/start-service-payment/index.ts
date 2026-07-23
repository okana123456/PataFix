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

function normalizePhone(phone: string) {
  let clean = String(phone || "").replace(/\D/g, "");
  if (clean.startsWith("0")) clean = `254${clean.slice(1)}`;
  if (clean.startsWith("7") || clean.startsWith("1")) clean = `254${clean}`;
  return clean;
}

function timestamp() {
  const d = new Date();
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function env(name: string) {
  return String(Deno.env.get(name) || Deno.env.get(name.replace("SERVICE_", "DARAJA_")) || "").trim();
}

function billingMonth() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-01`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    const { phone } = await req.json();
    const cleanPhone = normalizePhone(phone);
    if (!/^254(7|1)\d{8}$/.test(cleanPhone)) {
      return json({ ok: false, message: "Enter a valid Safaricom phone number." }, 400);
    }

    const supabaseUrl = Deno.env.get("PATAFIX_PROJECT_URL") || "";
    const serviceKey = Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "";
    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData } = await supabase.auth.getUser(jwt);
    const user = userData?.user;
    if (!user) return json({ ok: false, message: "Please sign in again." }, 401);

    const { data: staff } = await supabase
      .from("loan_staff")
      .select("id, business_id, role, is_active")
      .eq("auth_user_id", user.id)
      .maybeSingle();
    if (!staff?.is_active || !["admin", "branch_manager"].includes(staff.role)) {
      return json({ ok: false, message: "Only admins can renew the system subscription." }, 403);
    }

    const amount = Math.max(1, Number(Deno.env.get("SERVICE_BILLING_AMOUNT") || 3000));
    const shortcode = env("SERVICE_SHORTCODE");
    const consumerKey = env("SERVICE_CONSUMER_KEY");
    const consumerSecret = env("SERVICE_CONSUMER_SECRET");
    const passkey = env("SERVICE_PASSKEY");
    const transactionType = Deno.env.get("SERVICE_TRANSACTION_TYPE") || "CustomerPayBillOnline";
    const mode = (Deno.env.get("SERVICE_DARAJA_ENVIRONMENT") || "production").toLowerCase();

    if (!consumerKey || !consumerSecret || !passkey || !shortcode) {
      return json({
        ok: false,
        message: "Service Daraja credentials are missing. Add SERVICE_CONSUMER_KEY, SERVICE_CONSUMER_SECRET, SERVICE_PASSKEY and SERVICE_SHORTCODE in Supabase secrets.",
      }, 400);
    }

    const baseUrl = mode === "sandbox" ? "https://sandbox.safaricom.co.ke" : "https://api.safaricom.co.ke";
    const oauthRes = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${consumerKey}:${consumerSecret}`)}` },
    });
    const oauth = await oauthRes.json();
    if (!oauthRes.ok || !oauth.access_token) {
      return json({ ok: false, message: oauth.errorMessage || oauth.error_description || "Daraja OAuth failed.", response: oauth }, 400);
    }

    const ts = timestamp();
    const callbackUrl = Deno.env.get("SERVICE_CALLBACK_URL") || `${supabaseUrl}/functions/v1/service-payment-callback`;
    const accountReference = `PATA${String(staff.business_id).replace(/[^a-z0-9]/gi, "").slice(-7).toUpperCase()}`.slice(0, 12);
    const payload = {
      BusinessShortCode: Number(shortcode),
      Password: btoa(`${shortcode}${passkey}${ts}`),
      Timestamp: ts,
      TransactionType: transactionType,
      Amount: amount,
      PartyA: Number(cleanPhone),
      PartyB: Number(shortcode),
      PhoneNumber: Number(cleanPhone),
      CallBackURL: callbackUrl,
      AccountReference: accountReference,
      TransactionDesc: "PataFix system subscription",
    };

    const stkRes = await fetch(`${baseUrl}/mpesa/stkpush/v1/processrequest`, {
      method: "POST",
      headers: { Authorization: `Bearer ${oauth.access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const stk = await stkRes.json();
    if (!stkRes.ok || stk.ResponseCode !== "0") {
      return json({
        ok: false,
        message: stk.errorMessage || stk.ResponseDescription || "M-Pesa prompt failed. Check shortcode, passkey and transaction type.",
        response: stk,
      }, 400);
    }

    const cycle = {
      business_id: staff.business_id,
      billing_month: billingMonth(),
      amount,
      status: "initiated",
      phone: cleanPhone,
      merchant_request_id: stk.MerchantRequestID,
      checkout_request_id: stk.CheckoutRequestID,
      result_description: stk.ResponseDescription,
    };

    const { error: saveError } = await supabase
      .from("loan_billing_cycles")
      .upsert(cycle, { onConflict: "business_id,billing_month" });
    if (saveError) {
      return json({
        ok: false,
        message: `M-Pesa prompt was sent, but PataFix could not save the payment request: ${saveError.message}`,
        checkout_request_id: stk.CheckoutRequestID,
      }, 500);
    }

    return json({
      ok: true,
      message: "Subscription payment prompt sent.",
      amount,
      checkout_request_id: stk.CheckoutRequestID,
      customer_message: stk.CustomerMessage,
    });
  } catch (error) {
    return json({ ok: false, message: error instanceof Error ? error.message : String(error) }, 500);
  }
});
