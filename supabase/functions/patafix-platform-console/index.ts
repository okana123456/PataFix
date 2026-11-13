import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function text(value: unknown) {
  return String(value ?? "").trim();
}

function slugify(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48);
}

function firstDayOfNextMonth() {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString().slice(0, 10);
}

function defaultProducts(businessId: string) {
  return [
    {
      business_id: businessId,
      name: "INUA BIZ",
      description: "KES 5,000-10,000 | configurable weekly loan",
      min_amount: 5000,
      max_amount: 10000,
      interest_rate: 20,
      interest_period: "monthly",
      interest_type: "flat",
      min_term_weeks: 1,
      max_term_weeks: 52,
      processing_fee_type: "flat",
      processing_fee_value: 500,
      processing_fee_pct: 0,
      registration_fee: 200,
      repayment_frequency: "weekly",
      term_unit: "weeks",
      requires_guarantor: true,
      is_active: true,
    },
    {
      business_id: businessId,
      name: "KUZA",
      description: "KES 11,000-15,000 | configurable weekly loan",
      min_amount: 11000,
      max_amount: 15000,
      interest_rate: 20,
      interest_period: "monthly",
      interest_type: "flat",
      min_term_weeks: 1,
      max_term_weeks: 52,
      processing_fee_type: "percent",
      processing_fee_value: 5,
      processing_fee_pct: 5,
      registration_fee: 300,
      repayment_frequency: "weekly",
      term_unit: "weeks",
      requires_guarantor: true,
      is_active: true,
    },
    {
      business_id: businessId,
      name: "NAWIRI",
      description: "KES 16,000-20,000 | configurable weekly loan",
      min_amount: 16000,
      max_amount: 20000,
      interest_rate: 20,
      interest_period: "monthly",
      interest_type: "flat",
      min_term_weeks: 1,
      max_term_weeks: 52,
      processing_fee_type: "percent",
      processing_fee_value: 6,
      processing_fee_pct: 6,
      registration_fee: 400,
      repayment_frequency: "weekly",
      term_unit: "weeks",
      requires_guarantor: true,
      is_active: true,
    },
  ];
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST" }, 405);

  const supabaseUrl = text(Deno.env.get("PATAFIX_PROJECT_URL"));
  const serviceRoleKey = text(Deno.env.get("PATAFIX_SERVICE_ROLE_KEY"));
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ ok: false, message: "Platform server secrets are incomplete." }, 500);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: userData, error: userError } = await admin.auth.getUser(jwt);
    const user = userData?.user;
    if (userError || !user) return json({ ok: false, message: "Please sign in again." }, 401);

    const { data: platformAdmin, error: adminError } = await admin
      .from("patafix_platform_admins")
      .select("id,email,full_name,is_active")
      .eq("auth_user_id", user.id)
      .maybeSingle();
    if (adminError) throw adminError;
    if (!platformAdmin?.is_active) {
      return json({ ok: false, message: "This account is not authorised for the platform console." }, 403);
    }

    const payload = await req.json().catch(() => ({}));
    const action = text(payload.action || "dashboard");

    if (action === "dashboard") {
      const [{ data: businesses, error: businessError }, { data: plans, error: planError }, { data: payments, error: paymentError }] = await Promise.all([
        admin.from("patafix_platform_businesses").select("*,patafix_platform_plans(*)").order("created_at", { ascending: false }),
        admin.from("patafix_platform_plans").select("*").order("sort_order"),
        admin.from("patafix_platform_payments").select("*").order("created_at", { ascending: false }).limit(100),
      ]);
      if (businessError) throw businessError;
      if (planError) throw planError;
      if (paymentError) throw paymentError;

      const rows = await Promise.all((businesses || []).map(async (business) => {
        const businessId = business.business_id;
        const [clients, staff, activeLoans, branches] = await Promise.all([
          admin.from("loan_clients").select("id", { count: "exact", head: true }).eq("business_id", businessId),
          admin.from("loan_staff").select("id", { count: "exact", head: true }).eq("business_id", businessId).eq("is_active", true),
          admin.from("loans").select("id", { count: "exact", head: true }).eq("business_id", businessId).eq("status", "active"),
          admin.from("patafix_branches").select("id", { count: "exact", head: true }).eq("business_id", businessId).eq("is_active", true),
        ]);
        return {
          ...business,
          counts: {
            clients: clients.count || 0,
            staff: staff.count || 0,
            active_loans: activeLoans.count || 0,
            branches: branches.count || 0,
          },
        };
      }));

      return json({ ok: true, admin: platformAdmin, businesses: rows, plans: plans || [], payments: payments || [] });
    }

    if (action === "create_business") {
      const businessName = text(payload.businessName);
      const adminName = text(payload.adminName);
      const email = text(payload.email).toLowerCase();
      const password = String(payload.password || "");
      const planCode = text(payload.planCode || "starter").toLowerCase();
      if (!businessName || !adminName || !email || password.length < 8) {
        return json({ ok: false, message: "Enter the business, administrator, email and a password of at least 8 characters." }, 400);
      }

      const { data: plan, error: planError } = await admin
        .from("patafix_platform_plans")
        .select("*")
        .eq("code", planCode)
        .eq("is_active", true)
        .single();
      if (planError || !plan) return json({ ok: false, message: "Select a valid active package." }, 400);

      const { data: existingStaff } = await admin.from("loan_staff").select("id").ilike("email", email).limit(1);
      if (existingStaff?.length) return json({ ok: false, message: "That administrator email is already registered." }, 409);

      const { data: createdUser, error: createUserError } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { full_name: adminName, business_name: businessName, patafix_vendor: true },
      });
      if (createUserError || !createdUser.user) {
        return json({ ok: false, message: createUserError?.message || "Could not create the vendor administrator." }, 400);
      }

      const authUserId = createdUser.user.id;
      const businessId = `BIZ-${crypto.randomUUID().split("-")[0].toUpperCase()}`;
      const slug = `${slugify(businessName) || "vendor"}-${businessId.slice(-4).toLowerCase()}`;
      let staffId = "";

      try {
        const { data: staff, error: staffError } = await admin.from("loan_staff").insert({
          business_id: businessId,
          auth_user_id: authUserId,
          name: adminName,
          email,
          role: "admin",
          is_active: true,
        }).select("id").single();
        if (staffError) throw staffError;
        staffId = staff.id;

        const { error: settingsError } = await admin.from("loan_settings").insert({
          business_id: businessId,
          company_name: businessName,
          company_email: email,
          currency: "KES",
          default_grace_period: 7,
          default_late_penalty_pct: 0,
          default_processing_fee_pct: 0,
          standard_weekly_rate: 5,
          micro_weekly_rate: 5,
          micro_threshold: 5000,
          disbursement_method: "mpesa",
          mpesa_auto_confirm: true,
          enable_rollover_penalties: false,
        });
        if (settingsError) throw settingsError;

        const { error: branchError } = await admin.from("patafix_branches").insert({
          business_id: businessId,
          name: "Head Office",
          branch_code: "HO",
          status: "active",
        });
        if (branchError) throw branchError;

        const { error: productsError } = await admin.from("loan_products").insert(defaultProducts(businessId));
        if (productsError) throw productsError;

        const { error: businessError } = await admin.from("patafix_platform_businesses").insert({
          business_id: businessId,
          display_name: businessName,
          slug,
          status: "pending_onboarding",
          plan_id: plan.id,
          onboarding_fee: plan.onboarding_fee,
          onboarding_payment_status: "pending",
          subscription_start_date: null,
          created_by: platformAdmin.id,
          settings: { vendor_app_unchanged: true, enforcement_enabled: false },
        });
        if (businessError) throw businessError;

        const { error: membershipError } = await admin.from("patafix_platform_memberships").insert({
          business_id: businessId,
          auth_user_id: authUserId,
          staff_id: staffId,
          role: "admin",
          is_active: true,
        });
        if (membershipError) throw membershipError;

        await admin.from("patafix_platform_audit_log").insert({
          platform_admin_id: platformAdmin.id,
          business_id: businessId,
          action: "business_created",
          entity_type: "business",
          entity_id: businessId,
          new_value: { business_name: businessName, admin_name: adminName, email, plan_code: planCode },
        });

        return json({ ok: true, businessId, message: "Vendor created in pending onboarding status." });
      } catch (error) {
        if (businessId) {
          await admin.from("patafix_platform_memberships").delete().eq("business_id", businessId);
          await admin.from("patafix_platform_businesses").delete().eq("business_id", businessId);
          await admin.from("loan_products").delete().eq("business_id", businessId);
          await admin.from("patafix_branches").delete().eq("business_id", businessId);
          await admin.from("loan_settings").delete().eq("business_id", businessId);
          await admin.from("loan_staff").delete().eq("business_id", businessId);
        }
        await admin.auth.admin.deleteUser(authUserId).catch(() => undefined);
        throw error;
      }
    }

    if (action === "mark_onboarding_paid") {
      const businessId = text(payload.businessId);
      const reference = text(payload.reference);
      const phone = text(payload.phone);
      if (!businessId || !reference) return json({ ok: false, message: "Business and payment reference are required." }, 400);

      const { data: before, error: beforeError } = await admin.from("patafix_platform_businesses").select("*,patafix_platform_plans(*)").eq("business_id", businessId).single();
      if (beforeError || !before) return json({ ok: false, message: "Business not found." }, 404);
      if (before.onboarding_payment_status === "paid") return json({ ok: false, message: "Onboarding is already marked paid." }, 409);

      const amount = Number(before.onboarding_fee || before.patafix_platform_plans?.onboarding_fee || 7500);
      const paidAt = new Date().toISOString();
      const subscriptionStart = firstDayOfNextMonth();
      const { error: updateError } = await admin.from("patafix_platform_businesses").update({
        onboarding_payment_status: "paid",
        onboarding_paid_at: paidAt,
        subscription_start_date: subscriptionStart,
        status: "active",
      }).eq("business_id", businessId);
      if (updateError) throw updateError;

      const { error: paymentError } = await admin.from("patafix_platform_payments").insert({
        business_id: businessId,
        payment_type: "onboarding",
        amount,
        status: "paid",
        payment_method: "mpesa",
        payment_reference: reference,
        phone: phone || null,
        paid_at: paidAt,
        metadata: { subscription_start_date: subscriptionStart },
      });
      if (paymentError) throw paymentError;

      await admin.from("patafix_platform_audit_log").insert({
        platform_admin_id: platformAdmin.id,
        business_id: businessId,
        action: "onboarding_payment_confirmed",
        entity_type: "business",
        entity_id: businessId,
        old_value: before,
        new_value: { status: "active", reference, amount, subscription_start_date: subscriptionStart },
      });
      return json({ ok: true, subscriptionStart, message: "Onboarding paid and vendor activated." });
    }

    if (action === "update_business") {
      const businessId = text(payload.businessId);
      const allowedStatus = ["pending_onboarding", "trial", "active", "past_due", "suspended", "closed"];
      const updates: Record<string, unknown> = {};
      if (payload.status !== undefined) {
        const status = text(payload.status);
        if (!allowedStatus.includes(status)) return json({ ok: false, message: "Invalid business status." }, 400);
        updates.status = status;
      }
      if (payload.planCode !== undefined) {
        const { data: plan } = await admin.from("patafix_platform_plans").select("id").eq("code", text(payload.planCode)).single();
        if (!plan) return json({ ok: false, message: "Package not found." }, 400);
        updates.plan_id = plan.id;
      }
      for (const key of ["monthly_fee_override", "client_limit_override", "branch_limit_override"]) {
        if (payload[key] !== undefined) updates[key] = payload[key] === null || payload[key] === "" ? null : Number(payload[key]);
      }
      if (payload.notes !== undefined) updates.notes = text(payload.notes) || null;
      if (!businessId || !Object.keys(updates).length) return json({ ok: false, message: "No changes supplied." }, 400);

      const { data: before, error: beforeError } = await admin.from("patafix_platform_businesses").select("*").eq("business_id", businessId).single();
      if (beforeError) throw beforeError;
      const { data: after, error: updateError } = await admin.from("patafix_platform_businesses").update(updates).eq("business_id", businessId).select("*").single();
      if (updateError) throw updateError;
      await admin.from("patafix_platform_audit_log").insert({ platform_admin_id: platformAdmin.id, business_id: businessId, action: "business_updated", entity_type: "business", entity_id: businessId, old_value: before, new_value: after });
      return json({ ok: true, business: after });
    }

    if (action === "set_feature") {
      const businessId = text(payload.businessId);
      const featureKey = text(payload.featureKey).toLowerCase();
      if (!businessId || !/^[a-z0-9_]+$/.test(featureKey)) return json({ ok: false, message: "Business and valid feature key are required." }, 400);
      const enabled = Boolean(payload.enabled);
      const config = payload.config && typeof payload.config === "object" ? payload.config : {};
      const { data, error } = await admin.from("patafix_platform_feature_overrides").upsert({
        business_id: businessId,
        feature_key: featureKey,
        enabled,
        config,
        updated_by: platformAdmin.id,
      }, { onConflict: "business_id,feature_key" }).select("*").single();
      if (error) throw error;
      await admin.from("patafix_platform_audit_log").insert({ platform_admin_id: platformAdmin.id, business_id: businessId, action: "feature_override_updated", entity_type: "feature", entity_id: featureKey, new_value: data });
      return json({ ok: true, feature: data });
    }

    return json({ ok: false, message: "Unknown platform action." }, 400);
  } catch (error) {
    return json({ ok: false, message: error instanceof Error ? error.message : "Platform request failed." }, 500);
  }
});
