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

function mpesaDate(value: unknown) {
  const s = String(value || "").trim();
  if (/^\d{14}$/.test(s)) {
    return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T${s.slice(8, 10)}:${s.slice(10, 12)}:${s.slice(12, 14)}+03:00`;
  }
  return new Date().toISOString();
}

function currentScheduleInterestRatio(schedules: any[], loan: any) {
  let principalRemaining = 0;
  let interestRemaining = 0;
  for (const schedule of schedules || []) {
    const principalDue = Math.max(0, Number(schedule?.principal_due || 0));
    const interestDue = Math.max(0, Number(schedule?.interest_due || 0));
    const coreDue = principalDue + interestDue;
    if (coreDue <= 0) continue;
    const paidTowardCore = Math.min(coreDue, Math.max(0, Number(schedule?.total_paid || 0)));
    const remainingFactor = Math.max(0, (coreDue - paidTowardCore) / coreDue);
    principalRemaining += principalDue * remainingFactor;
    interestRemaining += interestDue * remainingFactor;
  }
  const remainingCore = principalRemaining + interestRemaining;
  if (remainingCore > 0) return Math.max(0, Math.min(1, interestRemaining / remainingCore));
  const totalPayable = Number(loan?.total_payable || 0);
  const totalInterest = Number(loan?.total_interest || 0);
  return totalPayable > 0 && totalInterest > 0
    ? Math.max(0, Math.min(1, totalInterest / totalPayable))
    : 0;
}

async function findClientByAccountId(supabase: any, businessId: string, accountNumber: string) {
  const accountDigits = digits(accountNumber);
  if (!accountDigits) return null;

  const { data, error } = await supabase
    .from("loan_clients")
    .select("id, business_id, full_name, id_number, phone")
    .eq("business_id", businessId)
    .eq("id_number", accountDigits)
    .limit(2);
  if (error) throw error;

  // An ID must identify exactly one client before money can post automatically.
  return data?.length === 1 ? data[0] : null;
}

async function recordUnmatchedPayment(
  supabase: any,
  { businessId, accountNumber, amount, transId, payerPhone, payerName, body }: any,
) {
  const { data: existing, error: lookupError } = await supabase
    .from("unmatched_payments")
    .select("id, resolved")
    .eq("business_id", businessId)
    .eq("mpesa_reference", transId)
    .limit(1)
    .maybeSingle();
  if (lookupError) throw lookupError;
  if (existing) return existing;

  const { data: inserted, error: insertError } = await supabase.from("unmatched_payments").insert({
    amount,
    account_number: accountNumber,
    business_id: businessId,
    mpesa_reference: transId,
    payer_phone: payerPhone,
    payer_name: payerName,
    payment_date: mpesaDate(body?.TransTime),
    raw_payload: body,
    resolved: false,
  }).select("id, resolved").single();
  if (insertError) throw insertError;
  return inserted;
}

serve(async (req) => {
  console.log("PataFix callback request", { method: req.method, url: req.url });
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  let trackedSupabase: any = null;
  let trackedQueueId: string | null = null;
  let trackedTransId = "";

  try {
    const body = await req.json();
    const transId = String(body?.TransID || "").trim();
    trackedTransId = transId;
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
    trackedSupabase = supabase;

    const { data: settings, error: settingsError } = await supabase
      .from("loan_settings")
      .select("business_id, mpesa_auto_confirm")
      .eq("mpesa_shortcode", shortcode)
      .maybeSingle();
    if (settingsError) throw settingsError;

    const { data: existingCallback, error: existingCallbackError } = await supabase
      .from("mpesa_callback_queue")
      .select("id, business_id, delivery_count, confirmed, unmatched, processing_status")
      .eq("trans_id", transId)
      .maybeSingle();
    if (existingCallbackError) throw existingCallbackError;

    const businessId = settings?.business_id || existingCallback?.business_id || null;
    let queue: any = existingCallback || null;
    if (existingCallback) {
      const { error: deliveryUpdateError } = await supabase
        .from("mpesa_callback_queue")
        .update({
          delivery_count: Math.max(1, Number(existingCallback.delivery_count || 1)) + 1,
          last_received_at: new Date().toISOString(),
        })
        .eq("id", existingCallback.id);
      if (deliveryUpdateError) throw deliveryUpdateError;
      trackedQueueId = existingCallback.id;

      const status = String(existingCallback.processing_status || "");
      if (existingCallback.unmatched || status === "suspense") {
        if (businessId) {
          await recordUnmatchedPayment(supabase, { businessId, accountNumber, amount, transId, payerPhone, payerName, body });
        }
        console.log("PataFix duplicate suspense callback verified", { transId });
        return accepted();
      }
      if (existingCallback.confirmed || ["processed_repayment", "processed_charges", "moved_to_capital"].includes(status)) {
        console.log("PataFix completed duplicate callback ignored", { transId, status });
        return accepted();
      }
      if (status === "pending_confirmation") {
        console.log("PataFix callback already awaiting manual confirmation", { transId });
        return accepted();
      }
      console.log("PataFix resuming incomplete callback", { transId, status });
    }

    if (queue?.id && businessId && queue.business_id !== businessId) {
      const { error: businessLinkError } = await supabase
        .from("mpesa_callback_queue")
        .update({ business_id: businessId })
        .eq("id", queue.id);
      if (businessLinkError) throw businessLinkError;
      queue.business_id = businessId;
    }

    console.log("PataFix callback business lookup", { transId, shortcode, businessId, autoConfirm: settings?.mpesa_auto_confirm });
    if (!queue) {
      const { data: insertedQueue, error: queueError } = await supabase
        .from("mpesa_callback_queue")
        .insert({
          business_id: businessId,
          transaction_type: body?.TransactionType || "C2B",
          trans_id: transId,
          trans_time: body?.TransTime,
          trans_amount: amount,
          business_short_code: shortcode,
          bill_ref_number: accountNumber,
          msisdn: payerPhone,
          first_name: payerName,
          raw_payload: body,
          confirmed: false,
          delivery_count: 1,
          last_received_at: new Date().toISOString(),
          processing_status: "received",
        })
        .select("id, business_id")
        .single();
      if (queueError) {
        throw queueError;
      }
      queue = insertedQueue;
      trackedQueueId = queue?.id || null;
    }

    if (!businessId) {
      if (queue?.id) {
        await supabase
          .from("mpesa_callback_queue")
          .update({
            processing_status: "business_not_found",
            processing_message: `No PataFix business matched shortcode ${shortcode}`,
          })
          .eq("id", queue.id);
      }
      console.log("PataFix callback stored without business match", { transId, shortcode });
      return accepted();
    }

    const client = await findClientByAccountId(supabase, businessId, accountNumber);
    if (!client) {
      console.log("PataFix callback unmatched client", { transId, businessId, accountNumber, payerPhone });
      await recordUnmatchedPayment(supabase, { businessId, accountNumber, amount, transId, payerPhone, payerName, body });
      if (queue?.id) {
        await supabase
          .from("mpesa_callback_queue")
          .update({
            confirmed: true,
            unmatched: true,
            unmatched_reason: "No matching client found",
            processing_status: "suspense",
            processing_message: `No client matched account ${accountNumber}`,
          })
          .eq("id", queue.id);
      }
      return accepted();
    }

    const { data: loan } = await supabase
      .from("loans")
      .select("id, client_id, loan_no, outstanding_balance, total_paid, total_payable, total_interest, status")
      .eq("business_id", businessId)
      .eq("client_id", client.id)
      .eq("status", "active")
      .gt("outstanding_balance", 0)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!loan) {
      const paymentDate = mpesaDate(body?.TransTime);
      const { error: chargeError } = await supabase
        .from("client_charge_transactions")
        .insert({
          business_id: businessId,
          client_id: client.id,
          transaction_type: "deposit",
          charge_type: "other",
          amount,
          transaction_date: paymentDate.slice(0, 10),
          reference: transId,
          payment_method: "mpesa_c2b",
          description: `M-Pesa deposit for registration/processing charges. Account: ${accountNumber}. Payer: ${payerName}`,
          source_key: `mpesa-charge:${transId}`,
        });
      if (chargeError && !String(chargeError.message || "").toLowerCase().includes("duplicate")) throw chargeError;

      await supabase.from("journal_entries").insert({
        business_id: businessId,
        date: paymentDate.slice(0, 10),
        ref: transId,
        description: `M-Pesa deposit to Charges & Excess for ${client.full_name || "client"} | Client ID: ${client.id} | Account: ${accountNumber}`,
        debit: "M-Pesa",
        credit: "Charges & Excess Account",
        amount,
        synced: false,
      });

      if (queue?.id) {
        await supabase
          .from("mpesa_callback_queue")
          .update({
            confirmed: true,
            processing_status: "processed_charges",
            processing_message: `Deposited to Charges & Excess for ${client.full_name || "client"}`,
          })
          .eq("id", queue.id);
      }
      console.log("PataFix callback confirmed charge deposit", { transId, businessId, clientId: client.id, amount });
      return accepted();
    }

    if (!settings?.mpesa_auto_confirm) {
      console.log("PataFix callback queued for manual confirmation", { transId, businessId, loanId: loan.id });
      if (queue?.id) {
        await supabase
          .from("mpesa_callback_queue")
          .update({
            loan_id: loan.id,
            processing_status: "pending_confirmation",
            processing_message: `Matched loan ${loan.loan_no || loan.id}; awaiting confirmation`,
          })
          .eq("id", queue.id);
      }
      return accepted();
    }

    const appliedAmount = Math.min(amount, Number(loan.outstanding_balance || 0));
    const excessAmount = Number(Math.max(0, amount - appliedAmount).toFixed(2));
    const { data: schedules } = await supabase
      .from("loan_schedules")
      .select("id, due_date, principal_due, interest_due, total_due, total_paid, status")
      .eq("loan_id", loan.id)
      .in("status", ["pending", "partial", "overdue"])
      .order("due_date", { ascending: true });
    const interestRatio = currentScheduleInterestRatio(schedules || [], loan);
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
    const newBalance = Math.max(0, Number((Number(loan.outstanding_balance || 0) - appliedAmount).toFixed(2)));
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

    if (excessAmount > 0) {
      const { error: excessError } = await supabase
        .from("client_charge_transactions")
        .insert({
          business_id: businessId,
          client_id: client.id,
          loan_id: loan.id,
          transaction_type: "excess_deposit",
          charge_type: "excess",
          amount: excessAmount,
          transaction_date: paymentDate.slice(0, 10),
          reference: transId,
          payment_method: "mpesa_c2b",
          description: `Amount paid above the remaining balance of loan ${loan.loan_no || loan.id}`,
          source_key: `mpesa-excess:${transId}`,
        });
      if (excessError && !String(excessError.message || "").toLowerCase().includes("duplicate")) throw excessError;

      await supabase.from("journal_entries").insert({
        business_id: businessId,
        date: paymentDate.slice(0, 10),
        ref: `${transId}-EXCESS`,
        description: `Excess repayment deposited to Charges & Excess | Loan ${loan.loan_no || loan.id} | Client ID: ${client.id}`,
        debit: "M-Pesa",
        credit: "Charges & Excess Account",
        amount: excessAmount,
        synced: false,
      });
    }

    if (queue?.id) {
      await supabase
        .from("mpesa_callback_queue")
        .update({
          confirmed: true,
          loan_id: loan.id,
          repayment_id: repayment.id,
          processing_status: "processed_repayment",
          processing_message: `Applied to loan ${loan.loan_no || loan.id}`,
        })
        .eq("id", queue.id);
    }

    console.log("PataFix callback confirmed repayment", { transId, businessId, clientId: client.id, loanId: loan.id, repaymentId: repayment.id, appliedAmount, excessAmount, newBalance });
    return accepted();
  } catch (error) {
    console.error("PataFix C2B callback error:", error);
    if (trackedSupabase && trackedQueueId) {
      try {
        const processingError = error instanceof Error ? error.message : String(error || "Unknown callback processing error");
        await trackedSupabase
          .from("mpesa_callback_queue")
          .update({
            processing_status: "processing_error",
            processing_message: processingError.slice(0, 500),
          })
          .eq("id", trackedQueueId);
      } catch (trackingError) {
        console.error("PataFix callback audit update failed", { trackedTransId, trackingError });
      }
    }
    return accepted();
  }
});
