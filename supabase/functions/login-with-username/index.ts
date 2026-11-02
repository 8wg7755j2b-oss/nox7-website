// Supabase Edge Function: login-with-username
// Deploy with --no-verify-jwt; this endpoint authenticates credentials itself.
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Methode nicht erlaubt." }, 405);

  try {
    const { username, password } = await req.json();
    if (typeof username !== "string" || typeof password !== "string" ||
        username.trim().length < 2 || password.length < 1) {
      return json({ error: "Anmeldung fehlgeschlagen. Bitte Zugangsdaten prüfen." }, 400);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!supabaseUrl || !anonKey || !serviceKey) {
      console.error("Supabase Edge Function environment is incomplete.");
      return json({ error: "Anmeldung derzeit nicht verfügbar." }, 500);
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const auth = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const normalized = username.trim().toLocaleLowerCase("de-AT");
    const { data: profile, error: profileError } = await admin
      .from("profiles")
      .select("id")
      .ilike("display_name", normalized)
      .eq("status", "active")
      .maybeSingle();

    if (profileError || !profile) {
      return json({ error: "Anmeldung fehlgeschlagen. Bitte Zugangsdaten prüfen." }, 401);
    }

    const { data: userData, error: userError } = await admin.auth.admin.getUserById(profile.id);
    const email = userData?.user?.email;
    if (userError || !email) {
      return json({ error: "Anmeldung fehlgeschlagen. Bitte Zugangsdaten prüfen." }, 401);
    }

    const { data, error } = await auth.auth.signInWithPassword({ email, password });
    if (error || !data.session) {
      return json({ error: "Anmeldung fehlgeschlagen. Bitte Zugangsdaten prüfen." }, 401);
    }

    const { access_token, refresh_token, expires_in, expires_at, token_type } = data.session;
    return json({
      session: { access_token, refresh_token, expires_in, expires_at, token_type },
    });
  } catch (error) {
    console.error("Username login failed:", error);
    return json({ error: "Anmeldung fehlgeschlagen. Bitte Zugangsdaten prüfen." }, 400);
  }
});
