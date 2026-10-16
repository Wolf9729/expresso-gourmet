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
check(rootHtml === nestedHtml, "root index.html and presentation entrypoint are identical");
check(/<!doctype html/i.test(rootHtml), "HTML document declaration exists");

const scripts = [...rootHtml.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)];
check(scripts.length === 1, "exactly one inline application script exists");

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
  ["/functions/v1/staff-admin", "employee invitations use the protected staff endpoint"],
  ["set_order_payment_status", "payment confirmation uses a transactional RPC"],
  ["set_product_availability", "product availability changes use a database RPC"],
]) {
  check(rootHtml.includes(fragment), label);
}

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
