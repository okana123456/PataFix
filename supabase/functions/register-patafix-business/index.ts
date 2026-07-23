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

async function secureEqual(left: string, right: string) {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const leftBytes = new Uint8Array(leftHash);
  const rightBytes = new Uint8Array(rightHash);
  let difference = 0;
  for (let index = 0; index < leftBytes.length; index += 1) {
    difference |= leftBytes[index] ^ rightBytes[index];
  }
  return difference === 0;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);

  try {
    const { businessName, adminName, email, password, registrationKey } = await req.json();
    const cleanBusinessName = String(businessName || "").trim();
    const cleanAdminName = String(adminName || "").trim();
    const cleanEmail = String(email || "").trim().toLowerCase();
    const cleanPassword = String(password || "");
    const suppliedKey = String(registrationKey || "").trim();
    const expectedKey = String(Deno.env.get("PATAFIX_REGISTRATION_KEY") || "").trim();

    if (!expectedKey) return json({ ok: false, message: "Registration is not configured. Contact the platform owner." }, 503);
    if (!cleanBusinessName || !cleanAdminName || !cleanEmail || !cleanPassword || !suppliedKey) {
      return json({ ok: false, message: "Complete all registration fields." }, 400);
    }
    if (cleanPassword.length < 8) return json({ ok: false, message: "Password must be at least 8 characters." }, 400);
    if (!await secureEqual(suppliedKey, expectedKey)) {
      return json({ ok: false, message: "Invalid business registration key. Contact the PataFix platform owner." }, 403);
    }

    const supabaseUrl = Deno.env.get("PATAFIX_PROJECT_URL") || "";
    const anonKey = Deno.env.get("PATAFIX_ANON_KEY") || "";
    const serviceRoleKey = Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "";
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return json({ ok: false, message: "Supabase function secrets are incomplete." }, 500);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const publicAuth = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });

    const { data: existingStaff } = await admin
      .from("loan_staff")
      .select("id")
      .ilike("email", cleanEmail)
      .limit(1);
    if (existingStaff?.length) {
      return json({ ok: false, message: "This email is already registered. Use Sign In or Forgot Password." }, 409);
    }

    const { data: signUpData, error: signUpError } = await publicAuth.auth.signUp({
      email: cleanEmail,
      password: cleanPassword,
      options: { data: { full_name: cleanAdminName, business_name: cleanBusinessName } },
    });
    if (signUpError) return json({ ok: false, message: signUpError.message }, 400);
    const user = signUpData.user;
    if (!user || user.identities?.length === 0) {
      return json({ ok: false, message: "This email already has an account. Use Sign In or Forgot Password." }, 409);
    }

    const businessId = `BIZ-${crypto.randomUUID().split("-")[0].toUpperCase()}`;
    const { error: staffError } = await admin.from("loan_staff").insert({
      business_id: businessId,
      auth_user_id: user.id,
      name: cleanAdminName,
      email: cleanEmail,
      role: "admin",
      is_active: true,
    });
    if (staffError) {
      await admin.auth.admin.deleteUser(user.id).catch(() => undefined);
      return json({ ok: false, message: `Could not create the business administrator: ${staffError.message}` }, 500);
    }

    const { error: settingsError } = await admin.from("loan_settings").insert({
      business_id: businessId,
      company_name: cleanBusinessName,
      currency: "KES",
      standard_weekly_rate: 5,
      micro_weekly_rate: 5,
      micro_threshold: 5000,
      default_processing_fee_pct: 0,
      disbursement_method: "mpesa",
      mpesa_auto_confirm: true,
    });
    if (settingsError) {
      await admin.from("loan_staff").delete().eq("auth_user_id", user.id);
      await admin.auth.admin.deleteUser(user.id).catch(() => undefined);
      return json({ ok: false, message: `Could not create business settings: ${settingsError.message}` }, 500);
    }

    await admin.from("loan_products").insert([
      {
        business_id: businessId,
        name: "INUA BIZ",
        description: "5k-10k | registration fee KES 200 | interest 20% p.m | processing fee KES 500 flat | weekly payments",
        min_amount: 5000,
        max_amount: 10000,
        interest_rate: 20,
        interest_period: "monthly",
        interest_type: "flat",
        min_term_weeks: 1,
        max_term_weeks: 52,
        processing_fee_pct: 0,
        requires_guarantor: true,
        is_active: true,
      },
      {
        business_id: businessId,
        name: "KUZA",
        description: "11k-15k | registration fee KES 300 | interest 20% p.m | processing fee 5% of principal | weekly payments",
        min_amount: 11000,
        max_amount: 15000,
        interest_rate: 20,
        interest_period: "monthly",
        interest_type: "flat",
        min_term_weeks: 1,
        max_term_weeks: 52,
        processing_fee_pct: 5,
        requires_guarantor: true,
        is_active: true,
      },
      {
        business_id: businessId,
        name: "NAWIRI",
        description: "16k-20k | registration fee KES 400 | interest 20% p.m | application fee 6% of principal | weekly payments",
        min_amount: 16000,
        max_amount: 20000,
        interest_rate: 20,
        interest_period: "monthly",
        interest_type: "flat",
        min_term_weeks: 1,
        max_term_weeks: 52,
        processing_fee_pct: 6,
        requires_guarantor: true,
        is_active: true,
      },
      {
        business_id: businessId,
        name: "KOMANZA",
        description: "16k-40k | registration fee KES 400 | interest 18% p.m | application fee 10% of principal | biweekly payments",
        min_amount: 16000,
        max_amount: 40000,
        interest_rate: 18,
        interest_period: "monthly",
        interest_type: "flat",
        min_term_weeks: 2,
        max_term_weeks: 52,
        processing_fee_pct: 10,
        requires_guarantor: true,
        is_active: true,
      },
    ]);

    return json({
      ok: true,
      businessId,
      requiresEmailConfirmation: !signUpData.session,
      message: "Business registered successfully.",
    });
  } catch (error) {
    return json({ ok: false, message: error instanceof Error ? error.message : "Registration failed" }, 500);
  }
});
