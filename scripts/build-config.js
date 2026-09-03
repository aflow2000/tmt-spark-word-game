/* ============================================================
   Vercel / CI build step — writes assets/spark-word-config.js from
   environment variables so no key is ever pasted by hand.

   Works with the Supabase integration from the Vercel Marketplace, which
   injects SUPABASE_URL / SUPABASE_ANON_KEY (and NEXT_PUBLIC_* twins).
   If no variables are present the file is left untouched, so local
   double-click previews keep working in design-preview mode.
   ============================================================ */
const fs = require("fs");
const path = require("path");
const env = process.env;
const url = env.SUPABASE_URL || env.NEXT_PUBLIC_SUPABASE_URL || "";
const key = env.SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || "";
const site = env.SITE_URL || (env.VERCEL_PROJECT_PRODUCTION_URL ? "https://" + env.VERCEL_PROJECT_PRODUCTION_URL : (env.VERCEL_URL ? "https://" + env.VERCEL_URL : ""));
const urlStyle = env.URL_STYLE || "path";
const target = path.join(__dirname, "..", "assets", "spark-word-config.js");

if (!url || !key) {
  console.log("[spark-word] No SUPABASE_URL / SUPABASE_ANON_KEY in the environment — leaving assets/spark-word-config.js as is (design preview).");
  process.exit(0);
}

/* Single-file editions (spark-word.html / spark-word-admin.html) carry their
   CONFIG block inline — patch the same values there when the files exist.
   siteUrl is only written when SITE_URL is set explicitly: the page
   auto-detects its own address otherwise. */
for (const f of ["spark-word.html", "spark-word-admin.html"]) {
  const file = path.join(__dirname, "..", f);
  if (!fs.existsSync(file)) continue;
  let s = fs.readFileSync(file, "utf8");
  const block = s.match(/window\.SPARK_WORD_CONFIG\s*=\s*\{[\s\S]*?\};/);
  if (!block) { console.log("[spark-word] " + f + ": no CONFIG block found, skipped"); continue; }
  let b = block[0]
    .replace(/(supabaseUrl:\s*)"[^"]*"/, "$1" + JSON.stringify(url))
    .replace(/(supabaseAnonKey:\s*)"[^"]*"/, "$1" + JSON.stringify(key));
  if (env.SITE_URL) b = b.replace(/(siteUrl:\s*)"[^"]*"/, "$1" + JSON.stringify(env.SITE_URL));
  if (env.URL_STYLE) b = b.replace(/(urlStyle:\s*)"[^"]*"/, "$1" + JSON.stringify(env.URL_STYLE));
  s = s.replace(block[0], b);
  fs.writeFileSync(file, s);
  console.log("[spark-word] Patched CONFIG block in " + f);
}
const js = `/* Generated at build time by scripts/build-config.js from environment variables. Do not edit by hand. */
window.SPARK_WORD_CONFIG = {
  supabaseUrl: ${JSON.stringify(url)},
  supabaseAnonKey: ${JSON.stringify(key)},
  siteUrl: ${JSON.stringify(site)},
  urlStyle: ${JSON.stringify(urlStyle)},
  analytics: null
};
`;
fs.writeFileSync(target, js);
console.log("[spark-word] Wrote assets/spark-word-config.js for " + url + (site ? " (site " + site + ")" : ""));
