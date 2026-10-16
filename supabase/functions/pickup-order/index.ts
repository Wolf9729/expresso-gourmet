import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const ALLOWED_ORIGINS = new Set([
  "https://expresso-gourmet.vercel.app",
  "https://expresso-gourmet-alysson-projects1.vercel.app",
  "http://localhost:3000",
  "http://127.0.0.1:3000",
]);

function allowedOrigin(origin: string): boolean {
  return ALLOWED_ORIGINS.has(origin) ||
    /^https:\/\/expresso-gourmet-[a-z0-9]+-alysson-projects1\.vercel\.app$/.test(origin);
}

function corsHeaders(origin: string): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, idempotency-key",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function json(status: number, body: unknown, origin: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function normalizePhone(value: string): string {
  return value.replace(/\D/g, "");
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") ?? "";
  if (!allowedOrigin(origin)) {
    return new Response("Origin not allowed", { status: 403, headers: { "Cache-Control": "no-store" } });
  }
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(origin) });
  }
  if (request.method !== "POST") {
    return json(405, { error: { code: "METHOD_NOT_ALLOWED", message: "Use POST para enviar um pedido." } }, origin);
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json(503, { error: { code: "CHECKOUT_UNAVAILABLE", message: "O recebimento de pedidos está temporariamente indisponível." } }, origin);
  }

  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > 24_000) {
    return json(413, { error: { code: "PAYLOAD_TOO_LARGE", message: "Pedido muito grande." } }, origin);
  }

  let body: Record<string, unknown>;
  try {
    const text = await request.text();
    if (text.length > 24_000) {
      return json(413, { error: { code: "PAYLOAD_TOO_LARGE", message: "Pedido muito grande." } }, origin);
    }
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid");
    body = parsed as Record<string, unknown>;
  } catch {
    return json(400, { error: { code: "INVALID_JSON", message: "Não foi possível interpretar o pedido." } }, origin);
  }

  const customerName = String(body.customerName ?? "").trim();
  const phone = normalizePhone(String(body.phone ?? ""));
  const paymentMethod = String(body.paymentMethod ?? "").toLowerCase();
  const notes = String(body.notes ?? "").trim();
  const itemsRaw = body.items;
  const idempotencyKey = String(
    body.idempotencyKey ?? request.headers.get("idempotency-key") ?? crypto.randomUUID(),
  ).trim();

  if (customerName.length < 2 || customerName.length > 100) {
    return json(400, { error: { code: "INVALID_NAME", message: "Informe seu nome (2 a 100 caracteres)." } }, origin);
  }
  if (phone.length < 10 || phone.length > 13) {
    return json(400, { error: { code: "INVALID_PHONE", message: "Informe um WhatsApp com DDD válido." } }, origin);
  }
  if (!["pix", "cash", "debit", "credit", "other"].includes(paymentMethod)) {
    return json(400, { error: { code: "INVALID_PAYMENT_METHOD", message: "Selecione uma forma de pagamento válida." } }, origin);
  }
  if (notes.length > 400) {
    return json(400, { error: { code: "NOTES_TOO_LONG", message: "As observações podem ter até 400 caracteres." } }, origin);
  }
  if (!Array.isArray(itemsRaw) || itemsRaw.length < 1 || itemsRaw.length > 25) {
    return json(400, { error: { code: "INVALID_ITEMS", message: "O pedido deve ter de 1 a 25 itens diferentes." } }, origin);
  }
  if (!isUuid(idempotencyKey)) {
    return json(400, { error: { code: "INVALID_IDEMPOTENCY_KEY", message: "Atualize a página e tente novamente." } }, origin);
  }

  const requestedItems: Array<{ productId: string; quantity: number; notes?: string }> = [];
  const seenIds = new Set<string>();
  for (const item of itemsRaw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return json(400, { error: { code: "INVALID_ITEM", message: "Um item do pedido está inválido." } }, origin);
    }
    const row = item as Record<string, unknown>;
    const productId = String(row.productId ?? "").trim();
    const quantity = Number(row.quantity);
    const itemNotes = String(row.notes ?? "").trim();
    if (!/^[A-Za-z0-9_-]{1,80}$/.test(productId) || !Number.isInteger(quantity) || quantity < 1 || quantity > 20 || itemNotes.length > 160) {
      return json(400, { error: { code: "INVALID_ITEM", message: "Confira a quantidade e os dados dos produtos." } }, origin);
    }
    if (seenIds.has(productId)) {
      return json(400, { error: { code: "DUPLICATE_ITEM", message: "Agrupe as quantidades do mesmo produto na sacola." } }, origin);
    }
    seenIds.add(productId);
    requestedItems.push({ productId, quantity, notes: itemNotes || undefined });
  }

  const forwarded = request.headers.get("x-forwarded-for") ?? "";
  const clientIp = request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    forwarded.split(",")[0].trim() ??
    "unknown";
  const limiterKey = await sha256(`${SERVICE_ROLE_KEY}:${clientIp || "unknown"}`);
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const { data: allowed, error: rateError } = await supabase.rpc("consume_checkout_rate_limit", {
      p_key_hash: limiterKey,
    });
    if (rateError) {
      console.error("[pickup-order] rate limiter unavailable");
      return json(503, { error: { code: "CHECKOUT_BUSY", message: "O recebimento está ocupado. Aguarde um instante e tente novamente." } }, origin);
    }
    if (allowed !== true) {
      return json(429, { error: { code: "RATE_LIMITED", message: "Muitos pedidos foram enviados deste dispositivo. Aguarde alguns minutos." } }, origin);
    }

    const { data: catalogRow, error: catalogError } = await supabase
      .from("expresso_public_catalog")
      .select("payload")
      .eq("id", true)
      .maybeSingle();
    if (catalogError || !catalogRow) {
      return json(503, { error: { code: "CATALOG_UNAVAILABLE", message: "Não foi possível validar o cardápio agora." } }, origin);
    }
    const settings = (catalogRow.payload as Record<string, unknown>)?.settings as Record<string, unknown> | undefined;
    if (settings?.acceptOrders !== true) {
      return json(409, { error: { code: "ORDERS_PAUSED", message: "A loja pausou temporariamente os pedidos online." } }, origin);
    }

    const requestedIds = requestedItems.map((item) => item.productId);
    const legacyIds = requestedIds.filter((id) => !isUuid(id));
    const uuidIds = requestedIds.filter(isUuid);
    const foundProducts = new Map<string, { id: string; legacy_id: string | null; active: boolean; available: boolean }>();

    if (legacyIds.length) {
      const { data, error } = await supabase
        .from("products")
        .select("id,legacy_id,active,available")
        .in("legacy_id", legacyIds)
        .eq("active", true)
        .eq("available", true);
      if (error) {
        return json(503, { error: { code: "PRODUCT_LOOKUP_FAILED", message: "Não foi possível validar os produtos." } }, origin);
      }
      for (const product of data ?? []) {
        if (product.legacy_id) foundProducts.set(product.legacy_id, product);
      }
    }
    if (uuidIds.length) {
      const { data, error } = await supabase
        .from("products")
        .select("id,legacy_id,active,available")
        .in("id", uuidIds)
        .eq("active", true)
        .eq("available", true);
      if (error) {
        return json(503, { error: { code: "PRODUCT_LOOKUP_FAILED", message: "Não foi possível validar os produtos." } }, origin);
      }
      for (const product of data ?? []) {
        foundProducts.set(product.id, product);
        if (product.legacy_id) foundProducts.set(product.legacy_id, product);
      }
    }

    if (requestedItems.some((item) => !foundProducts.has(item.productId))) {
      return json(409, { error: { code: "PRODUCT_UNAVAILABLE", message: "Um ou mais produtos acabaram de ficar indisponíveis. Atualize o cardápio e tente novamente." } }, origin);
    }

    const databaseItems = requestedItems.map((item) => ({
      product_id: foundProducts.get(item.productId)!.id,
      quantity: item.quantity,
      notes: item.notes ?? null,
    }));

    const { data: orderId, error: createError } = await supabase.rpc("create_staff_order", {
      p_customer_name: customerName,
      p_items: databaseItems,
      p_customer_phone: phone,
      p_course_id: null,
      p_campaign_id: null,
      p_enrollment_code: null,
      p_payment_method: paymentMethod,
      p_notes: notes || null,
      p_source: "site",
      p_external_id: idempotencyKey,
    });
    if (createError || !orderId) {
      console.error("[pickup-order] order creation rejected", createError?.code ?? "unknown");
      const message = createError?.message ?? "";
      if (/indisponível|disponível/i.test(message)) {
        return json(409, { error: { code: "PRODUCT_UNAVAILABLE", message: "Um ou mais produtos estão indisponíveis. Atualize o cardápio e tente novamente." } }, origin);
      }
      return json(400, { error: { code: "ORDER_NOT_CREATED", message: "O pedido não foi concluído. Confira seus dados e tente novamente." } }, origin);
    }

    const { data: order, error: orderReadError } = await supabase
      .from("orders")
      .select("order_number,total,subtotal,discount_amount,status,payment_status")
      .eq("source", "site")
      .eq("external_id", idempotencyKey)
      .maybeSingle();
    if (orderReadError || !order) {
      return json(202, {
        order: { id: orderId, pickupToken: idempotencyKey, status: "new" },
        message: "Seu pedido foi registrado. Guarde o código e consulte a equipe caso o comprovante não apareça.",
      }, origin);
    }

    return json(201, {
      order: {
        id: orderId,
        orderNumber: order.order_number,
        pickupToken: idempotencyKey,
        pickupCode: `EG-${idempotencyKey.replace(/-/g, "").slice(-6).toUpperCase()}`,
        subtotal: Number(order.subtotal) || 0,
        discount: Number(order.discount_amount) || 0,
        total: Number(order.total) || 0,
        status: order.status,
        paymentStatus: order.payment_status,
        fulfillment: "pickup",
      },
    }, origin);
  } catch (error) {
    console.error("[pickup-order] unexpected failure", error instanceof Error ? error.name : "unknown");
    return json(500, { error: { code: "INTERNAL_ERROR", message: "Não foi possível concluir o pedido. Tente novamente." } }, origin);
  }
});
