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
  const now = new Date(Date.now() + 3 * 60 * 60 * 1000);
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString().slice(0, 10);
}

function lastDayOfMonth(value: string) {
  const [year, month] = value.slice(0, 10).split("-").map(Number);
  if (!year || !month) throw new Error("Enter a valid billing month.");
  return new Date(Date.UTC(year, month, 0)).toISOString().slice(0, 10);
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
          admin.from("patafix_branches").select("id", { count: "exact", head: true }).eq("business_id", businessId).eq("status", "active"),
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

    if (action === "business_detail") {
      const businessId = text(payload.businessId);
      if (!businessId) return json({ ok: false, message: "Business is required." }, 400);

      const { data: business, error: businessError } = await admin
        .from("patafix_platform_businesses")
        .select("*,patafix_platform_plans(*)")
        .eq("business_id", businessId)
        .single();
      if (businessError || !business) return json({ ok: false, message: "Business not found." }, 404);

      const [settingsResult, branchesResult, productsResult, staffResult, routeResult, overridesResult, billingResult] = await Promise.all([
        admin.from("loan_settings").select("business_id,company_name,company_phone,company_email,company_address,currency,mpesa_shortcode,daraja_environment,daraja_credentials_saved,mpesa_auto_confirm").eq("business_id", businessId).maybeSingle(),
        admin.from("patafix_branches").select("id,name,branch_code,manager_name,phone,location,status").eq("business_id", businessId).order("name"),
        admin.from("loan_products").select("id,name,description,min_amount,max_amount,interest_rate,interest_period,min_term_weeks,max_term_weeks,processing_fee_type,processing_fee_value,registration_fee,repayment_frequency,term_unit,requires_guarantor,is_active").eq("business_id", businessId).order("min_amount"),
        admin.from("loan_staff").select("id,name,email,phone,role,is_active,branch_name").eq("business_id", businessId).order("created_at"),
        admin.from("patafix_payment_routes").select("provider,shortcode,environment,status,validation_url,confirmation_url,registered_at,last_verified_at").eq("business_id", businessId).maybeSingle(),
        admin.from("patafix_platform_feature_overrides").select("feature_key,enabled,config").eq("business_id", businessId),
        admin.from("loan_billing_cycles").select("billing_month,amount,status,phone,receipt_number,paid_at,paid_until,result_description").eq("business_id", businessId).order("billing_month", { ascending: false }).limit(12),
      ]);
      for (const result of [settingsResult, branchesResult, productsResult, staffResult, routeResult, overridesResult, billingResult]) {
        if (result.error) throw result.error;
      }

      const settings = settingsResult.data;
      const branches = branchesResult.data || [];
      const products = productsResult.data || [];
      const staff = staffResult.data || [];
      const route = routeResult.data;
      return json({
        ok: true,
        business,
        settings,
        branches,
        products,
        staff,
        paymentRoute: route,
        featureOverrides: overridesResult.data || [],
        billingCycles: billingResult.data || [],
        checklist: {
          company_profile: Boolean(settings?.company_name && settings?.company_phone && settings?.company_email),
          administrator: staff.some((member: any) => member.is_active && String(member.role || "").split(",").map((role: string) => role.trim()).includes("admin")),
          branch: branches.some((branch: any) => branch.status === "active"),
          loan_products: products.some((product: any) => product.is_active),
          daraja: Boolean(route?.status === "active" && settings?.daraja_credentials_saved),
          onboarding: ["paid", "waived"].includes(String(business.onboarding_payment_status || "")),
        },
      });
    }

    if (action === "update_vendor_profile") {
      const businessId = text(payload.businessId);
      const companyName = text(payload.companyName);
      const companyPhone = text(payload.companyPhone);
      const companyEmail = text(payload.companyEmail).toLowerCase();
      const companyAddress = text(payload.companyAddress);
      if (!businessId || !companyName) return json({ ok: false, message: "Business and company name are required." }, 400);

      const { data: before, error: beforeError } = await admin
        .from("loan_settings")
        .select("company_name,company_phone,company_email,company_address")
        .eq("business_id", businessId)
        .single();
      if (beforeError) throw beforeError;

      const profile = {
        company_name: companyName,
        company_phone: companyPhone || null,
        company_email: companyEmail || null,
        company_address: companyAddress || null,
      };
      const { error: settingsError } = await admin.from("loan_settings").update(profile).eq("business_id", businessId);
      if (settingsError) throw settingsError;
      const { error: platformError } = await admin.from("patafix_platform_businesses").update({ display_name: companyName }).eq("business_id", businessId);
      if (platformError) throw platformError;

      await admin.from("patafix_platform_audit_log").insert({
        platform_admin_id: platformAdmin.id,
        business_id: businessId,
        action: "vendor_profile_updated",
        entity_type: "loan_settings",
        entity_id: businessId,
        old_value: before,
        new_value: profile,
      });
      return json({ ok: true, message: "Vendor profile updated." });
    }

    if (action === "record_subscription_payment") {
      const businessId = text(payload.businessId);
      const reference = text(payload.reference);
      const phone = text(payload.phone);
      const rawMonth = text(payload.billingMonth);
      const billingMonth = /^\d{4}-\d{2}$/.test(rawMonth) ? `${rawMonth}-01` : rawMonth;
      if (!businessId || !reference || !/^\d{4}-\d{2}-01$/.test(billingMonth)) {
        return json({ ok: false, message: "Business, payment reference and a valid billing month are required." }, 400);
      }

      const { data: business, error: businessError } = await admin
        .from("patafix_platform_businesses")
        .select("monthly_fee_override,patafix_platform_plans(monthly_fee)")
        .eq("business_id", businessId)
        .single();
      if (businessError) throw businessError;
      const amount = Math.max(1, Number(payload.amount || business.monthly_fee_override || business.patafix_platform_plans?.monthly_fee || 3000));
      const paidAt = new Date().toISOString();
      const paidUntil = lastDayOfMonth(billingMonth);

      const { data: cycle, error: cycleError } = await admin.from("loan_billing_cycles").upsert({
        business_id: businessId,
        billing_month: billingMonth,
        amount,
        status: "paid",
        phone: phone || null,
        receipt_number: reference,
        result_code: "0",
        result_description: "Subscription payment recorded by platform owner",
        paid_at: paidAt,
        paid_until: paidUntil,
        metadata: { source: "platform_console", platform_admin_id: platformAdmin.id },
      }, { onConflict: "business_id,billing_month" }).select("*").single();
      if (cycleError) throw cycleError;

      const { error: paymentError } = await admin.from("patafix_platform_payments").upsert({
        business_id: businessId,
        payment_type: "subscription",
        billing_month: billingMonth,
        amount,
        status: "paid",
        payment_method: text(payload.paymentMethod) || "manual",
        payment_reference: reference,
        phone: phone || null,
        paid_at: paidAt,
        metadata: { paid_until: paidUntil, source: "platform_console" },
      }, { onConflict: "business_id,payment_type,payment_reference" });
      if (paymentError) throw paymentError;

      await admin.from("patafix_platform_businesses").update({ status: "active" }).eq("business_id", businessId).in("status", ["past_due", "active"]);
      await admin.from("patafix_platform_audit_log").insert({ platform_admin_id: platformAdmin.id, business_id: businessId, action: "subscription_payment_recorded", entity_type: "loan_billing_cycles", entity_id: cycle.id, new_value: cycle });
      return json({ ok: true, cycle, message: "Subscription payment recorded and access restored." });
    }

    if (action === "save_branch") {
      const businessId = text(payload.businessId);
      const branchId = text(payload.branchId);
      const name = text(payload.name);
      if (!businessId || !name) return json({ ok: false, message: "Business and branch name are required." }, 400);

      const { data: business, error: businessError } = await admin
        .from("patafix_platform_businesses")
        .select("branch_limit_override,patafix_platform_plans(max_branches)")
        .eq("business_id", businessId)
        .single();
      if (businessError) throw businessError;

      if (!branchId) {
        const { count, error: countError } = await admin.from("patafix_branches").select("id", { count: "exact", head: true }).eq("business_id", businessId).eq("status", "active");
        if (countError) throw countError;
        const branchLimit = business.branch_limit_override ?? business.patafix_platform_plans?.max_branches ?? null;
        if (branchLimit && Number(count || 0) >= Number(branchLimit)) {
          return json({ ok: false, message: `This package allows ${branchLimit} active branch${Number(branchLimit) === 1 ? "" : "es"}. Upgrade or add an override first.` }, 409);
        }
      }

      const record = {
        business_id: businessId,
        name,
        branch_code: text(payload.branchCode) || null,
        manager_name: text(payload.managerName) || null,
        phone: text(payload.phone) || null,
        location: text(payload.location) || null,
        status: text(payload.status) === "inactive" ? "inactive" : "active",
      };
      let saved;
      if (branchId) {
        const result = await admin.from("patafix_branches").update(record).eq("id", branchId).eq("business_id", businessId).select("*").single();
        if (result.error) throw result.error;
        saved = result.data;
      } else {
        const result = await admin.from("patafix_branches").insert(record).select("*").single();
        if (result.error) throw result.error;
        saved = result.data;
      }
      await admin.from("patafix_platform_audit_log").insert({ platform_admin_id: platformAdmin.id, business_id: businessId, action: branchId ? "branch_updated" : "branch_created", entity_type: "patafix_branches", entity_id: saved.id, new_value: saved });
      return json({ ok: true, branch: saved });
    }

    if (action === "save_product") {
      const businessId = text(payload.businessId);
      const productId = text(payload.productId);
      const name = text(payload.name);
      const minAmount = Number(payload.minAmount);
      const maxAmount = Number(payload.maxAmount);
      const interestRate = Number(payload.interestRate);
      const minTermWeeks = Number(payload.minTermWeeks);
      const maxTermWeeks = Number(payload.maxTermWeeks);
      if (!businessId || !name || minAmount < 0 || maxAmount < minAmount || interestRate < 0 || minTermWeeks < 1 || maxTermWeeks < minTermWeeks) {
        return json({ ok: false, message: "Enter a valid product name, amount range, interest rate and term range." }, 400);
      }
      const processingFeeType = text(payload.processingFeeType) === "flat" ? "flat" : "percent";
      const processingFeeValue = Math.max(0, Number(payload.processingFeeValue || 0));
      const record = {
        business_id: businessId,
        name,
        description: text(payload.description) || null,
        min_amount: minAmount,
        max_amount: maxAmount,
        interest_rate: interestRate,
        interest_type: "flat",
        interest_period: ["weekly", "monthly", "term"].includes(text(payload.interestPeriod)) ? text(payload.interestPeriod) : "weekly",
        min_term_weeks: minTermWeeks,
        max_term_weeks: maxTermWeeks,
        processing_fee_type: processingFeeType,
        processing_fee_value: processingFeeValue,
        processing_fee_pct: processingFeeType === "percent" ? processingFeeValue : 0,
        registration_fee: Math.max(0, Number(payload.registrationFee || 0)),
        repayment_frequency: ["weekly", "biweekly", "monthly"].includes(text(payload.repaymentFrequency)) ? text(payload.repaymentFrequency) : "weekly",
        term_unit: text(payload.termUnit) === "months" ? "months" : "weeks",
        requires_guarantor: Boolean(payload.requiresGuarantor),
        is_active: payload.isActive !== false,
      };
      let saved;
      if (productId) {
        const result = await admin.from("loan_products").update(record).eq("id", productId).eq("business_id", businessId).select("*").single();
        if (result.error) throw result.error;
        saved = result.data;
      } else {
        const result = await admin.from("loan_products").insert(record).select("*").single();
        if (result.error) throw result.error;
        saved = result.data;
      }
      await admin.from("patafix_platform_audit_log").insert({ platform_admin_id: platformAdmin.id, business_id: businessId, action: productId ? "loan_product_updated" : "loan_product_created", entity_type: "loan_products", entity_id: saved.id, new_value: saved });
      return json({ ok: true, product: saved });
    }

    if (action === "create_business") {
      const businessName = text(payload.businessName);
      const adminName = text(payload.adminName);
      const email = text(payload.email).toLowerCase();
      const password = String(payload.password || "");
      const planCode = text(payload.planCode || "starter").toLowerCase();
      const demoMode = payload.demoMode === true;
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
          status: demoMode ? "active" : "pending_onboarding",
          plan_id: plan.id,
          onboarding_fee: demoMode ? 0 : plan.onboarding_fee,
          onboarding_payment_status: demoMode ? "waived" : "pending",
          subscription_start_date: null,
          created_by: platformAdmin.id,
          settings: { vendor_app_unchanged: true, enforcement_enabled: !demoMode, demo_mode: demoMode },
          notes: demoMode ? "Platform demonstration tenant. No live financial integrations." : null,
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
          new_value: { business_name: businessName, admin_name: adminName, email, plan_code: planCode, demo_mode: demoMode },
        });

        return json({ ok: true, businessId, message: demoMode ? "Demo business created and activated." : "Vendor created in pending onboarding status." });
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
