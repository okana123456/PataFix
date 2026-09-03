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

function splitRoles(role: unknown) {
  return String(role || "").split(",").map((item) => item.trim()).filter(Boolean);
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST" }, 405);

  try {
    const supabaseUrl = Deno.env.get("PATAFIX_PROJECT_URL") || "";
    const serviceRoleKey = Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "";
    if (!supabaseUrl || !serviceRoleKey) {
      return json({ ok: false, message: "PataFix Supabase secrets are incomplete." }, 500);
    }

    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData } = await admin.auth.getUser(jwt);
    const signedInUser = userData?.user;
    if (!signedInUser) return json({ ok: false, message: "Please sign in again." }, 401);

    const { data: requester, error: requesterError } = await admin
      .from("loan_staff")
      .select("id,business_id,role,is_active")
      .eq("auth_user_id", signedInUser.id)
      .maybeSingle();
    if (requesterError) return json({ ok: false, message: requesterError.message }, 500);
    if (!requester?.is_active || !splitRoles(requester.role).includes("admin")) {
      return json({ ok: false, message: "Only administrators can manage staff login access." }, 403);
    }

    const {
      action,
      staff_id: staffId,
      name,
      email,
      phone,
      branch_name: branchName,
      password,
      role,
      permissions,
      is_active: isActive,
    } = await req.json();

    if (action === "list") {
      const { data: staff, error: staffError } = await admin
        .from("loan_staff")
        .select("*")
        .eq("business_id", requester.business_id)
        .order("name", { ascending: true });
      if (staffError) return json({ ok: false, message: staffError.message }, 500);

      const enriched = await Promise.all((staff || []).map(async (row) => {
        let emailConfirmedAt: string | null = null;
        let authExists = false;
        if (row.auth_user_id) {
          const { data: authUserData, error: authUserError } = await admin.auth.admin.getUserById(row.auth_user_id);
          const authUser = authUserData?.user;
          authExists = !authUserError && !!authUser;
          emailConfirmedAt = authUser?.email_confirmed_at || null;
        }
        return {
          ...row,
          auth_exists: authExists,
          email_confirmed_at: emailConfirmedAt,
          invite_status: row.auth_user_id && !emailConfirmedAt ? "pending_email" : (row.is_active ? "active" : "inactive"),
        };
      }));

      return json({ ok: true, staff: enriched });
    }

    if (action === "create_staff") {
      const cleanName = String(name || "").trim();
      const cleanEmail = String(email || "").trim().toLowerCase();
      const cleanPassword = String(password || "");
      const cleanRole = String(role || "").trim();
      if (!cleanName || !cleanEmail || !cleanPassword || !cleanRole) {
        return json({ ok: false, message: "Name, email, password and role are required." }, 400);
      }
      if (cleanPassword.length < 6) {
        return json({ ok: false, message: "Password must be at least 6 characters." }, 400);
      }

      const { data: existingStaff } = await admin
        .from("loan_staff")
        .select("id")
        .eq("business_id", requester.business_id)
        .ilike("email", cleanEmail)
        .limit(1);
      if (existingStaff?.length) {
        return json({ ok: false, message: "This email is already listed under staff." }, 409);
      }

      const { data: authData, error: createAuthError } = await admin.auth.admin.createUser({
        email: cleanEmail,
        password: cleanPassword,
        email_confirm: true,
        user_metadata: { full_name: cleanName, patafix_business_id: requester.business_id },
      });
      if (createAuthError) return json({ ok: false, message: createAuthError.message }, 400);
      const authUser = authData?.user;
      if (!authUser) return json({ ok: false, message: "Could not create staff login." }, 500);

      const { data: insertedStaff, error: insertStaffError } = await admin
        .from("loan_staff")
        .insert({
          business_id: requester.business_id,
          auth_user_id: authUser.id,
          name: cleanName,
          email: cleanEmail,
          phone: String(phone || "").trim() || null,
          branch_name: String(branchName || "Head Office").trim() || "Head Office",
          role: cleanRole,
          permissions: permissions && typeof permissions === "object" ? permissions : {},
          is_active: isActive !== false,
        })
        .select("id")
        .single();
      if (insertStaffError) {
        await admin.auth.admin.deleteUser(authUser.id).catch(() => undefined);
        return json({ ok: false, message: insertStaffError.message }, 500);
      }

      await admin.from("loan_audit_log").insert({
        business_id: requester.business_id,
        user_id: requester.id,
        action: "staff_created_with_confirmed_login",
        table_name: "loan_staff",
        record_id: insertedStaff.id,
        new_value: { email: cleanEmail, name: cleanName, role: cleanRole },
      }).catch(() => undefined);

      return json({ ok: true, message: "Staff created. They can sign in immediately.", staff_id: insertedStaff.id });
    }

    const { data: staffRecord, error: staffError } = await admin
      .from("loan_staff")
      .select("id,business_id,auth_user_id,email,name")
      .eq("id", staffId || "")
      .eq("business_id", requester.business_id)
      .maybeSingle();
    if (staffError) return json({ ok: false, message: staffError.message }, 500);
    if (!staffRecord) return json({ ok: false, message: "Staff member was not found." }, 404);

    if (action === "reset_password") {
      const cleanPassword = String(password || "");
      if (!staffRecord.auth_user_id) return json({ ok: false, message: "This staff member has no linked login account." }, 400);
      if (cleanPassword.length < 6) return json({ ok: false, message: "Password must be at least 6 characters." }, 400);
      const { error: resetError } = await admin.auth.admin.updateUserById(staffRecord.auth_user_id, {
        password: cleanPassword,
        email_confirm: true,
      });
      if (resetError) return json({ ok: false, message: resetError.message }, 400);
      await admin.from("loan_audit_log").insert({
        business_id: requester.business_id,
        user_id: requester.id,
        action: "staff_password_reset_by_admin",
        table_name: "loan_staff",
        record_id: staffRecord.id,
        new_value: { email: staffRecord.email, name: staffRecord.name },
      }).catch(() => undefined);
      return json({ ok: true, message: "Password updated. Staff can sign in immediately." });
    }

    if (action === "delete") {
      if (staffRecord.id === requester.id) {
        return json({ ok: false, message: "You cannot delete your own staff account while signed in." }, 400);
      }
      const authUserId = staffRecord.auth_user_id;
      const { error: deleteStaffError } = await admin.from("loan_staff").delete().eq("id", staffRecord.id);
      if (deleteStaffError) return json({ ok: false, message: deleteStaffError.message }, 500);
      if (authUserId) {
        await admin.auth.admin.deleteUser(authUserId).catch(() => undefined);
      }
      await admin.from("loan_audit_log").insert({
        business_id: requester.business_id,
        user_id: requester.id,
        action: "staff_deleted_with_login",
        table_name: "loan_staff",
        record_id: staffRecord.id,
        new_value: { email: staffRecord.email, name: staffRecord.name },
      }).catch(() => undefined);
      return json({ ok: true, message: "Staff member deleted completely." });
    }

    return json({ ok: false, message: "Unknown staff management action." }, 400);
  } catch (error) {
    return json({ ok: false, message: error instanceof Error ? error.message : "Staff management failed" }, 500);
  }
});
