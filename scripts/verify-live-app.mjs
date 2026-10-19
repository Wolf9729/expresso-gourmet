import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const root = process.cwd();
const fail = [];
const pass = [];
function check(condition, label) {
  (condition ? pass : fail).push(label);
}

const rootHtml = readFileSync(join(root, "index.html"), "utf8");
const nestedHtml = readFileSync(join(root, "presentation", "index.html"), "utf8");
const publicHtml = readFileSync(join(root, "public", "presentation", "index.html"), "utf8");
check(rootHtml === nestedHtml, "root index.html and presentation entrypoint are identical");
check(rootHtml === publicHtml, "public legacy entrypoint has no stale demo copy");
check(/<!doctype html/i.test(rootHtml), "HTML document declaration exists");

const scriptElements = [...rootHtml.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)];
const scripts = scriptElements.filter((match) => match[1].trim().length > 0);
check(scripts.length === 1, "exactly one inline application script exists");
check(rootHtml.includes("supabase-js@2.110.0/dist/umd/supabase.js"), "pinned Supabase Realtime client is loaded");

if (scripts.length === 1) {
  const temporary = mkdtempSync(join(tmpdir(), "expresso-gourmet-check-"));
  const scriptPath = join(temporary, "application.js");
  try {
    writeFileSync(scriptPath, scripts[0][1], "utf8");
    const result = spawnSync(process.execPath, ["--check", scriptPath], { encoding: "utf8" });
    check(result.status === 0, result.status === 0
      ? "application JavaScript syntax passes node --check"
      : "application JavaScript syntax passes node --check: " + (result.stderr || result.stdout || "unknown error").trim());
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

for (const [fragment, label] of [
  ["/rest/v1/expresso_public_catalog", "public catalog reads from Supabase"],
  ["/functions/v1/pickup-order", "checkout uses the real pickup Edge Function"],
  ["get_public_order_confirmation", "pickup status reads the persisted order"],
  ["get_sales_dashboard", "analytics uses the database sales RPC"],
  ["admin_save_product", "owner product edits use a transactional database RPC"],
  ["admin_update_store_settings", "store settings persist through an owner-only RPC"],
  ["set_order_payment_status", "payment confirmation uses a transactional RPC"],
  ["set_product_availability", "product availability changes use a database RPC"],
  ["advance_order_status", "order state transitions use a database RPC"],
  ["function cancelOrder(", "the staff UI supports safe cancellation of eligible orders"],
  ["Novos convites temporariamente pausados", "the UI does not expose an unverified staff invite flow"],
  ["/rest/v1/categories?", "the admin editor reads live categories"],
  ["/rest/v1/business_settings?", "the owner settings screen reads persisted store settings"],
  ["connectOrdersRealtime", "staff queue initializes authenticated Realtime"],
  ["postgres_changes", "staff queue listens for database order events"],
  ["setAuth(staffSession.access_token)", "Realtime uses the validated staff session"],
  ["function refreshStaffSessionIfNeeded(force)", "staff sessions are refreshed before expiry"],
  ["async function staffFetch(url,options)", "authenticated requests use refreshed credentials"],
]) {
  check(rootHtml.includes(fragment), label);
}

check(!rootHtml.includes("method:'PATCH',headers:Object.assign(staffAuthHeaders(),{Prefer:'return=minimal'}),body:JSON.stringify({status:transition[0]})"), "no direct client-side order status mutation");

const staffAdminSource = readFileSync(join(root, "supabase/functions/staff-admin/index.ts"), "utf8");
check(staffAdminSource.includes("admin.auth.getUser(token)") && staffAdminSource.includes('profile?.role !== "owner"') && staffAdminSource.includes("profile?.active !== true"), "staff-admin endpoint validates an active owner before inviting");
check(!rootHtml.includes("team-invite-form") && !rootHtml.includes("function inviteTeamMember("), "no unverified invitation form can submit from the browser");

const categoryMigration = readFileSync(join(root, "supabase/migrations/20261018171000_fix_authenticated_category_reads.sql"), "utf8");
check(categoryMigration.includes("grant select on table public.categories to authenticated"), "category read permission is present in the SQL migration");
check(categoryMigration.includes("revoke insert, update, delete on table public.categories from authenticated"), "direct category mutations are restricted in the SQL migration");
const rateLimitMigration = readFileSync(join(root, "supabase/migrations/20261018172000_explicit_rate_limit_denial_and_legacy_indexes.sql"), "utf8");
check(rateLimitMigration.includes("using (false)") && rateLimitMigration.includes("with check (false)"), "checkout rate-limit table explicitly denies browser roles");
check(rateLimitMigration.includes("expresso_owner_private_state_updated_by_idx"), "legacy foreign-key index is present in the SQL migration");
check(!rootHtml.includes("fetch(URL+'/rest/v1/rpc/advance_order_status"), "order status changes use the refresh-aware authenticated wrapper");

for (const [fragment, label] of [
  ["var demo=[", "no seeded demonstration catalog"],
  ["function startDemo(", "no demo role switch"],
  ["function buildDemoAnalytics(", "no fabricated sales dataset"],
  ["isDemoMode", "no demo application state"],
  ["demo:true", "no orders marked as demo"],
  ["Demonstração ·", "no demo-only staff identity"],
]) {
  check(!rootHtml.includes(fragment), label);
}

for (const path of [
  "supabase/migrations/20261016141000_normalize_live_catalog_and_checkout.sql",
  "supabase/migrations/20261016142000_backfill_legacy_cost_snapshots.sql",
  "supabase/migrations/20261016143000_owner_product_admin_functions.sql",
  "supabase/migrations/20261016144000_transactional_payment_confirmation.sql",
  "supabase/migrations/20261016145000_sales_dashboard_owner_only.sql",
  "supabase/migrations/20261016150000_restrict_direct_order_mutations.sql",
  "supabase/migrations/20261016152000_enable_order_realtime.sql",
  "supabase/migrations/20261018170000_harden_order_transitions_and_admin_reads.sql",
  "supabase/migrations/20261018171000_fix_authenticated_category_reads.sql",
  "supabase/migrations/20261018172000_explicit_rate_limit_denial_and_legacy_indexes.sql",
  "supabase/functions/pickup-order/index.ts",
  "supabase/functions/staff-admin/index.ts",
]) {
  try {
    readFileSync(join(root, path), "utf8");
    pass.push("source file exists: " + path);
  } catch {
    fail.push("source file exists: " + path);
  }
}

for (const label of pass) console.log("PASS " + label);
for (const label of fail) console.error("FAIL " + label);

if (fail.length) {
  console.error("\n" + fail.length + " check(s) failed; " + pass.length + " passed.");
  process.exitCode = 1;
} else {
  console.log("\nAll " + pass.length + " live-source checks passed.");
}
