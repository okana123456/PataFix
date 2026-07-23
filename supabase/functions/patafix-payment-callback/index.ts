import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, prefer",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function accepted() {
  return new Response(JSON.stringify({ ResultCode: 0, ResultDesc: "Accepted" }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function digits(value: unknown) {
  return String(value || "").replace(/\D/g, "");
}

function phoneVariants(value: unknown) {
  const raw = digits(value);
  const out = new Set<string>();
  if (!raw) return [];
  out.add(raw);
  if (raw.length >= 9) out.add(raw.slice(-9));
  if (raw.length === 12 && raw.startsWith("254")) out.add(`0${raw.slice(3)}`);
  if (raw.length === 10 && raw.startsWith("0")) out.add(`254${raw.slice(1)}`);
  if (raw.length === 9 && /^[17]/.test(raw)) {
    out.add(`0${raw}`);
    out.add(`254${raw}`);
  }
  return [...out];
}

function mpesaDate(value: unknown) {
  const s = String(value || "").trim();
  if (/^\d{14}$/.test(s)) {
    return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T${s.slice(8, 10)}:${s.slice(10, 12)}:${s.slice(12, 14)}+03:00`;
  }
  return new Date().toISOString();
}

async function findClient(supabase: any, businessId: string, accountNumber: string, payerPhone: string) {
  const accountDigits = digits(accountNumber);
  if (accountDigits) {
    const { data } = await supabase
      .from("loan_clients")
      .select("id, business_id, full_name, id_number, phone")
      .eq("business_id", businessId)
      .eq("id_number", accountDigits)
      .maybeSingle();
    if (data) return data;
  }

  for (const candidate of phoneVariants(payerPhone)) {
    const { data } = await supabase
      .from("loan_clients")
      .select("id, business_id, full_name, id_number, phone")
      .eq("business_id", businessId)
      .eq("phone", candidate)
      .maybeSingle();
    if (data) return data;
  }

  for (const tail of phoneVariants(payerPhone).map((phone) => phone.slice(-9))) {
    const { data } = await supabase
      .from("loan_clients")
      .select("id, business_id, full_name, id_number, phone")
      .eq("business_id", businessId)
      .ilike("phone", `%${tail}`)
      .limit(1)
      .maybeSingle();
    if (data) return data;
  }

  return null;
}

serve(async (req) => {
  console.log("PataFix callback request", { method: req.method, url: req.url });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const body = await req.json();
    const transId = String(body?.TransID || "").trim();
    console.log("PataFix callback payload", {
      transId,
      amount: body?.TransAmount,
      shortcode: body?.BusinessShortCode,
      account: body?.BillRefNumber,
      phone: body?.MSISDN,
    });
    if (!transId) {
      console.log("PataFix callback ignored: missing TransID");
      return accepted();
    }

    const shortcode = String(body?.BusinessShortCode || "").trim();
    const accountNumber = String(body?.BillRefNumber || "").trim();
    const amount = Number(body?.TransAmount || 0);
    const payerPhone = String(body?.MSISDN || "").trim();
    const payerName = `${body?.FirstName || ""} ${body?.MiddleName || ""} ${body?.LastName || ""}`.replace(/\s+/g, " ").trim();
    if (!shortcode || !amount || amount <= 0) {
      console.log("PataFix callback ignored: missing shortcode or amount", { transId, shortcode, amount });
      return accepted();
    }

    const supabase = createClient(
      Deno.env.get("PATAFIX_PROJECT_URL") || "",
      Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "",
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const { data: settings } = await supabase
      .from("loan_settings")
      .select("business_id, mpesa_auto_confirm")
      .eq("mpesa_shortcode", shortcode)
      .maybeSingle();

    const businessId = settings?.business_id || null;
    console.log("PataFix callback business lookup", { transId, shortcode, businessId, autoConfirm: settings?.mpesa_auto_confirm });
    const { data: queue } = await supabase
      .from("mpesa_callback_queue")
      .insert({
        business_id: businessId,
        transaction_type: body?.TransactionType || "C2B",
        trans_id: transId,
        trans_time: body?.TransTime,
        trans_amount: amount,
        business_short_code: businessId || shortcode,
        bill_ref_number: accountNumber,
        msisdn: payerPhone,
        first_name: payerName,
        raw_payload: body,
        confirmed: false,
      })
      .select("id")
      .maybeSingle();

    if (!businessId) {
      console.log("PataFix callback stored without business match", { transId, shortcode });
      return accepted();
    }

    const client = await findClient(supabase, businessId, accountNumber, payerPhone);
    if (!client) {
      console.log("PataFix callback unmatched client", { transId, businessId, accountNumber, payerPhone });
      await supabase.from("unmatched_payments").insert({
        amount,
        account_number: accountNumber,
        business_id: businessId,
        mpesa_reference: transId,
        payer_phone: payerPhone,
        payer_name: payerName,
        raw_payload: body,
        resolved: false,
      });
      return accepted();
    }

    const { data: loan } = await supabase
      .from("loans")
      .select("id, outstanding_balance, total_paid, total_payable, total_interest, status")
      .eq("business_id", businessId)
      .eq("client_id", client.id)
      .eq("status", "active")
      .gt("outstanding_balance", 0)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!loan) {
      console.log("PataFix callback unmatched loan", { transId, businessId, clientId: client.id, amount });
      await supabase.from("unmatched_payments").insert({
        amount,
        account_number: accountNumber,
        business_id: businessId,
        mpesa_reference: transId,
        payer_phone: payerPhone,
        payer_name,
        raw_payload: body,
        resolved: false,
      });
      return accepted();
    }

    if (!settings?.mpesa_auto_confirm) {
      console.log("PataFix callback queued for manual confirmation", { transId, businessId, loanId: loan.id });
      if (queue?.id) await supabase.from("mpesa_callback_queue").update({ loan_id: loan.id }).eq("id", queue.id);
      return accepted();
    }

    const appliedAmount = Math.min(amount, Number(loan.outstanding_balance || 0));
    const totalPayable = Number(loan.total_payable || 0);
    const totalInterest = Number(loan.total_interest || 0);
    const interestRatio = totalPayable > 0 && totalInterest > 0 ? totalInterest / totalPayable : 0;
    const interestPortion = Number((appliedAmount * interestRatio).toFixed(2));
    const principalPortion = Number((appliedAmount - interestPortion).toFixed(2));
    const paymentDate = mpesaDate(body?.TransTime);

    const { data: repayment, error: repaymentError } = await supabase
      .from("loan_repayments")
      .insert({
        amount: appliedAmount,
        business_id: businessId,
        loan_id: loan.id,
        payment_method: "mpesa_c2b",
        payment_reference: transId,
        receipt_no: transId,
        mpesa_confirmed: true,
        payment_date: paymentDate,
        interest_portion: interestPortion,
        principal_portion: principalPortion,
        penalty_portion: 0,
        notes: `Auto-confirmed via Daraja C2B. Account number: ${accountNumber}. Payer: ${payerName}`,
      })
      .select("id")
      .single();
    if (repaymentError) throw repaymentError;

    const { data: schedules } = await supabase
      .from("loan_schedules")
      .select("id, due_date, total_due, total_paid, status")
      .eq("loan_id", loan.id)
      .in("status", ["pending", "partial", "overdue"])
      .order("due_date", { ascending: true });

    let remaining = appliedAmount;
    const today = new Date().toISOString().slice(0, 10);
    for (const schedule of schedules || []) {
      if (remaining <= 0) break;
      const due = Number(schedule.total_due || 0);
      const paid = Number(schedule.total_paid || 0);
      const owed = Math.max(0, due - paid);
      if (owed <= 0) continue;
      const apply = Math.min(remaining, owed);
      const newPaid = Number((paid + apply).toFixed(2));
      const newStatus = newPaid >= due ? "paid" : (schedule.due_date < today ? "overdue" : "partial");
      await supabase
        .from("loan_schedules")
        .update({ total_paid: newPaid, status: newStatus, paid_at: newStatus === "paid" ? paymentDate : null })
        .eq("id", schedule.id);
      remaining = Number((remaining - apply).toFixed(2));
    }

    const newTotalPaid = Number((Number(loan.total_paid || 0) + appliedAmount).toFixed(2));
    const newBalance = Math.max(0, Number((totalPayable - newTotalPaid).toFixed(2)));
    await supabase
      .from("loans")
      .update({
        total_paid: newTotalPaid,
        outstanding_balance: newBalance,
        status: newBalance <= 0 ? "completed" : loan.status,
        arrears_amount: newBalance <= 0 ? 0 : undefined,
        overdue_days: newBalance <= 0 ? 0 : undefined,
      })
      .eq("id", loan.id);

    if (queue?.id) {
      await supabase
        .from("mpesa_callback_queue")
        .update({ confirmed: true, loan_id: loan.id, repayment_id: repayment.id })
        .eq("id", queue.id);
    }

    console.log("PataFix callback confirmed repayment", { transId, businessId, clientId: client.id, loanId: loan.id, repaymentId: repayment.id, appliedAmount, newBalance });
    return accepted();
  } catch (error) {
    console.error("PataFix C2B callback error:", error);
    return accepted();
  }
});
