import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

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

function env(name: string) {
  return String(Deno.env.get(name) || Deno.env.get(name.replace("SERVICE_", "DARAJA_")) || "").trim();
}

function mask(value: string, expectedLength?: number) {
  return {
    seen: value ? `${value.slice(0, 4)}...${value.slice(-4)} (${value.length} chars)` : "missing",
    length: value.length,
    has_spaces: /\s/.test(value),
    expected_length: expectedLength || null,
    length_ok: expectedLength ? value.length === expectedLength : null,
  };
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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const body = await req.json().catch(() => ({}));
    const mode = String(body.mode || Deno.env.get("SERVICE_DARAJA_ENVIRONMENT") || "production").toLowerCase();
    const phone = normalizePhone(String(body.phone || ""));
    const amount = Math.max(1, Number(body.amount || 1));
    const shortcode = env("SERVICE_SHORTCODE");
    const consumerKey = env("SERVICE_CONSUMER_KEY");
    const consumerSecret = env("SERVICE_CONSUMER_SECRET");
    const passkey = env("SERVICE_PASSKEY");
    const transactionType = Deno.env.get("SERVICE_TRANSACTION_TYPE") || "CustomerPayBillOnline";

    const report: Record<string, unknown> = {
      mode,
      secrets_seen: {
        SERVICE_CONSUMER_KEY: mask(consumerKey, 48),
        SERVICE_CONSUMER_SECRET: mask(consumerSecret, 64),
        SERVICE_PASSKEY: mask(passkey, 64),
        SERVICE_SHORTCODE: mask(shortcode),
      },
    };

    if (!/^254(7|1)\d{8}$/.test(phone)) {
      return json({ ok: false, message: "Enter a valid Safaricom phone number.", report }, 400);
    }
    if (!consumerKey || !consumerSecret || !passkey || !shortcode) {
      return json({ ok: false, message: "Missing SERVICE_* secrets.", report }, 400);
    }

    const baseUrl = mode === "sandbox" ? "https://sandbox.safaricom.co.ke" : "https://api.safaricom.co.ke";
    const oauthRes = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${consumerKey}:${consumerSecret}`)}` },
    });
    const oauth = await oauthRes.json();
    report.oauth = { ok: oauthRes.ok, status: oauthRes.status, response: oauth };
    if (!oauthRes.ok || !oauth.access_token) {
      return json({ ok: false, message: "OAuth failed. Check consumer key and consumer secret.", report });
    }

    const ts = timestamp();
    const payload = {
      BusinessShortCode: Number(shortcode),
      Password: btoa(`${shortcode}${passkey}${ts}`),
      Timestamp: ts,
      TransactionType: transactionType,
      Amount: amount,
      PartyA: Number(phone),
      PartyB: Number(shortcode),
      PhoneNumber: Number(phone),
      CallBackURL: String(body.callback_url || "https://example.com/callback"),
      AccountReference: "PATAFIX",
      TransactionDesc: "PataFix subscription diagnostic",
    };

    const stkRes = await fetch(`${baseUrl}/mpesa/stkpush/v1/processrequest`, {
      method: "POST",
      headers: { Authorization: `Bearer ${oauth.access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const stk = await stkRes.json();
    report.stk = {
      ok: stkRes.ok && stk.ResponseCode === "0",
      status: stkRes.status,
      response: stk,
      sent_without_password: { ...payload, Password: "[hidden]" },
    };

    if (!stkRes.ok || stk.ResponseCode !== "0") {
      return json({ ok: false, message: "STK failed. Check response.", report });
    }
    return json({ ok: true, message: "STK accepted. PataFix service Daraja setup works.", report });
  } catch (error) {
    return json({ ok: false, message: error instanceof Error ? error.message : String(error) }, 500);
  }
});
