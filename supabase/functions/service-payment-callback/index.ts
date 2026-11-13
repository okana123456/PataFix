import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, prefer",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function response() {
  return new Response(JSON.stringify({ ResultCode: 0, ResultDesc: "Accepted" }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function metadataValue(items: Array<{ Name: string; Value: unknown }> | undefined, name: string) {
  return items?.find((item) => item.Name === name)?.Value ?? null;
}

function addDaysFromLater(currentPaidUntil: string | null, days = 30) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const current = currentPaidUntil ? new Date(`${currentPaidUntil}T00:00:00`) : today;
  const base = current > today ? current : today;
  base.setDate(base.getDate() + days);
  return base.toISOString().slice(0, 10);
}

function monthEnd(value: string) {
  const [year, month] = String(value || "").slice(0, 10).split("-").map(Number);
  if (!year || !month) return addDaysFromLater(null, 30);
  return new Date(Date.UTC(year, month, 0)).toISOString().slice(0, 10);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const payload = await req.json();
    const callback = payload?.Body?.stkCallback || payload?.stkCallback || payload;
    const checkoutRequestId = String(callback?.CheckoutRequestID || "").trim();
    const merchantRequestId = String(callback?.MerchantRequestID || "").trim();
    const resultCode = String(callback?.ResultCode ?? "");
    const resultDescription = String(callback?.ResultDesc || callback?.ResponseDescription || "");
    if (!checkoutRequestId) return response();

    const supabase = createClient(
      Deno.env.get("PATAFIX_PROJECT_URL") || "",
      Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "",
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const { data: cycle } = await supabase
      .from("loan_billing_cycles")
      .select("*")
      .eq("checkout_request_id", checkoutRequestId)
      .maybeSingle();
    if (!cycle) return response();

    if (resultCode !== "0") {
      await supabase
        .from("loan_billing_cycles")
        .update({
          status: "failed",
          result_code: resultCode,
          result_description: resultDescription || "Payment was not completed.",
          merchant_request_id: merchantRequestId || cycle.merchant_request_id,
        })
        .eq("id", cycle.id);
      return response();
    }

    const items = callback?.CallbackMetadata?.Item || [];
    const receipt = String(metadataValue(items, "MpesaReceiptNumber") || `STK-${checkoutRequestId.slice(-10)}`);
    const phone = String(metadataValue(items, "PhoneNumber") || cycle.phone || "");
    const paidAt = new Date().toISOString();
    const managed = cycle?.metadata?.managed_subscription === true;
    const paidUntil = managed ? monthEnd(cycle.billing_month) : addDaysFromLater(cycle.paid_until || null, 30);

    await supabase
      .from("loan_billing_cycles")
      .update({
        status: "paid",
        result_code: "0",
        result_description: resultDescription || "Payment successful",
        receipt_number: receipt,
        phone,
        paid_at: paidAt,
        paid_until: paidUntil,
        merchant_request_id: merchantRequestId || cycle.merchant_request_id,
      })
      .eq("id", cycle.id);

    if (managed) {
      const { error: platformPaymentError } = await supabase
        .from("patafix_platform_payments")
        .upsert({
          business_id: cycle.business_id,
          payment_type: "subscription",
          billing_month: cycle.billing_month,
          amount: cycle.amount,
          status: "paid",
          payment_method: "mpesa_stk",
          payment_reference: receipt,
          phone,
          paid_at: paidAt,
          metadata: { checkout_request_id: checkoutRequestId, paid_until: paidUntil },
        }, { onConflict: "business_id,payment_type,payment_reference" });
      if (platformPaymentError) console.error("Platform subscription payment sync failed:", platformPaymentError);
    }

    return response();
  } catch (error) {
    console.error("PataFix service callback error:", error);
    return response();
  }
});
