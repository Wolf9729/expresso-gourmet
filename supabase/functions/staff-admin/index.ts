import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ALLOWED = new Set([
  "https://expresso-gourmet.vercel.app",
  "https://expresso-gourmet-alysson-projects1.vercel.app",
  "http://localhost:3000",
  "http://127.0.0.1:3000",
]);

function originAllowed(origin: string) {
  return ALLOWED.has(origin) ||
    /^https:\/\/expresso-gourmet-[a-z0-9]+-alysson-projects1\.vercel\.app$/.test(origin);
}
function cors(origin: string): Record<string,string> {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}
function reply(status: number, body: unknown, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {...cors(origin), "Content-Type":"application/json; charset=utf-8", "Cache-Control":"no-store", "X-Content-Type-Options":"nosniff"},
  });
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") ?? "";
  if (!originAllowed(origin)) return new Response("Origin not allowed", {status:403});
  if (request.method === "OPTIONS") return new Response("ok", {headers:cors(origin)});
  if (request.method !== "POST") return reply(405, {error:{message:"Use POST."}}, origin);
  if (!URL || !SERVICE_KEY) return reply(503, {error:{message:"Serviço de equipe indisponível."}}, origin);

  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7).trim() : "";
  if (!token) return reply(401, {error:{message:"Entre no painel para continuar."}}, origin);

  let body: Record<string, unknown>;
  try {
    const parsed = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid");
    body = parsed as Record<string, unknown>;
  } catch {
    return reply(400, {error:{message:"Corpo da solicitação inválido."}}, origin);
  }

  const action = String(body.action ?? "");
  const email = String(body.email ?? "").trim().toLowerCase();
  const fullName = String(body.fullName ?? "").trim();

  if (action !== "invite") return reply(400, {error:{message:"Ação não suportada."}}, origin);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 200) {
    return reply(400, {error:{message:"Informe um e-mail válido."}}, origin);
  }
  if (fullName.length < 2 || fullName.length > 100) {
    return reply(400, {error:{message:"Informe o nome do funcionário."}}, origin);
  }

  const admin = createClient(URL, SERVICE_KEY, {
    auth: {autoRefreshToken:false, persistSession:false},
  });

  try {
    const {data:userData,error:userError} = await admin.auth.getUser(token);
    if (userError || !userData.user) return reply(401, {error:{message:"Sessão inválida. Entre novamente."}}, origin);

    const {data:profile,error:profileError} = await admin
      .from("profiles").select("id,role,active").eq("id", userData.user.id).maybeSingle();
    if (profileError || profile?.role !== "owner" || profile?.active !== true) {
      return reply(403, {error:{message:"Somente a proprietária pode convidar funcionários."}}, origin);
    }

    const {data:inviteData,error:inviteError} = await admin.auth.admin.inviteUserByEmail(email, {
      data: {full_name: fullName},
      redirectTo: "https://expresso-gourmet.vercel.app/apresentacao.html",
    });
    if (inviteError || !inviteData.user) {
      console.error("[staff-admin] invitation rejected");
      return reply(400, {error:{message:"Não foi possível enviar o convite. Confira se o e-mail já possui conta e se o provedor de e-mail do Supabase está configurado."}}, origin);
    }

    const {error:upsertError} = await admin.from("profiles").upsert({
      id: inviteData.user.id,
      full_name: fullName,
      role: "employee",
      active: true,
    }, {onConflict:"id"});
    if (upsertError) {
      console.error("[staff-admin] profile setup failed");
      return reply(500, {error:{message:"O convite foi criado, mas não foi possível ativar o perfil. Peça à proprietária para revisar o cadastro."}}, origin);
    }

    return reply(201, {
      success: true,
      member: {id:inviteData.user.id, full_name:fullName, email, role:"employee", active:true},
      message:"Convite enviado. O funcionário deve aceitar o e-mail para concluir o acesso.",
    }, origin);
  } catch (error) {
    console.error("[staff-admin] unexpected failure", error instanceof Error ? error.name : "unknown");
    return reply(500, {error:{message:"Não foi possível concluir a solicitação de equipe."}}, origin);
  }
});
