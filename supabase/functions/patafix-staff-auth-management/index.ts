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
    const anonKey = Deno.env.get("PATAFIX_ANON_KEY") || "";
    const serviceRoleKey = Deno.env.get("PATAFIX_SERVICE_ROLE_KEY") || "";
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      return json({ ok: false, message: "PataFix Supabase secrets are incomplete." }, 500);
    }

    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const publicAuth = createClient(supabaseUrl, anonKey, {
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

    const { action, staff_id: staffId, email } = await req.json();

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

    const { data: staffRecord, error: staffError } = await admin
      .from("loan_staff")
      .select("id,business_id,auth_user_id,email,name")
      .eq("id", staffId || "")
      .eq("business_id", requester.business_id)
      .maybeSingle();
    if (staffError) return json({ ok: false, message: staffError.message }, 500);
    if (!staffRecord) return json({ ok: false, message: "Staff member was not found." }, 404);

    if (action === "resend_confirmation") {
      const staffEmail = String(staffRecord.email || email || "").trim().toLowerCase();
      if (!staffEmail) return json({ ok: false, message: "This staff member has no email address." }, 400);
      const { error: resendError } = await publicAuth.auth.resend({
        type: "signup",
        email: staffEmail,
        options: { emailRedirectTo: Deno.env.get("PATAFIX_APP_URL") || undefined },
      });
      if (resendError) return json({ ok: false, message: resendError.message }, 400);
      return json({ ok: true, message: `Confirmation email resent to ${staffEmail}.` });
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
