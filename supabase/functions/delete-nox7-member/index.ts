// Supabase Edge Function: delete-nox7-member
// Deploy with JWT verification enabled (default). The caller is re-verified below.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const PROTECTED_ADMIN_ID = "9cd89136-4682-4e6a-84ba-43c41327fa93";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Methode nicht erlaubt." }, 405);

  try {
    const authorization = req.headers.get("Authorization") || "";
    const token = authorization.replace(/^Bearer\s+/i, "");
    if (!token || token === authorization) return json({ error: "Anmeldung erforderlich." }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceKey) {
      console.error("Delete function environment is incomplete.");
      return json({ error: "Löschfunktion ist nicht vollständig konfiguriert." }, 500);
    }

    const authClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: callerData, error: callerError } = await authClient.auth.getUser(token);
    const caller = callerData?.user;
    if (callerError || !caller) return json({ error: "Sitzung ungültig oder abgelaufen." }, 401);

    const { data: callerProfile, error: callerProfileError } = await admin
      .from("profiles")
      .select("id, role, game_rank, status")
      .eq("id", caller.id)
      .maybeSingle();
    if (callerProfileError) {
      console.error("Could not verify caller profile:", callerProfileError);
      return json({ error: "Berechtigung konnte nicht geprüft werden." }, 500);
    }

    const isAdmin = callerProfile?.id === PROTECTED_ADMIN_ID && callerProfile?.role === "admin";
    const isLeadership = callerProfile?.status === "active" &&
      ["R4", "R5"].includes(callerProfile?.game_rank || "");
    if (!isAdmin && !isLeadership) return json({ error: "Keine Berechtigung zum Löschen von Mitgliedern." }, 403);

    const body = await req.json().catch(() => ({}));
    const targetId = body?.user_id;
    if (typeof targetId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(targetId)) {
      return json({ error: "Ungültige Mitglieds-ID." }, 400);
    }
    if (targetId === caller.id || targetId === PROTECTED_ADMIN_ID) {
      return json({ error: "Das eigene Konto und das geschützte ADMIN-Konto können nicht gelöscht werden." }, 403);
    }

    const { data: target, error: targetError } = await admin
      .from("profiles")
      .select("id, display_name, game_rank, role")
      .eq("id", targetId)
      .maybeSingle();
    if (targetError) return json({ error: "Mitglied konnte nicht geprüft werden." }, 500);
    if (!target) return json({ error: "Mitglied wurde nicht gefunden oder bereits gelöscht." }, 404);
    if (target.role === "admin" || target.game_rank === "R5") {
      return json({ error: "ADMIN- und R5-Konten sind geschützt und können nicht gelöscht werden." }, 403);
    }

    // Delete the Auth user, not just the profile row. Database foreign-key
    // ON DELETE CASCADE rules remove dependent profile data where configured.
    const { error: deleteError } = await admin.auth.admin.deleteUser(targetId);
    if (deleteError) {
      console.error("Auth user deletion failed:", deleteError);
      return json({ error: "Konto konnte nicht vollständig gelöscht werden: " + deleteError.message }, 500);
    }

    return json({ success: true, deleted_user_id: targetId, deleted_display_name: target.display_name || null });
  } catch (error) {
    console.error("Member deletion failed:", error);
    return json({ error: "Löschen fehlgeschlagen. Bitte erneut versuchen." }, 500);
  }
});
