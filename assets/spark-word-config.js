/* ============================================================
   SPARK WORD — configuration
   ------------------------------------------------------------
   ► CONFIGURATION STEP (the only credentials in the project):
     • Deploying on Vercel with the Supabase Marketplace integration?
       Do nothing — scripts/build-config.js rewrites this file at build
       time from the injected SUPABASE_URL / SUPABASE_ANON_KEY variables.
     • Anywhere else: paste the project URL and the *anon* (public) key
       below. Never put the service_role key in this file.
   Leave both empty to run the in-memory design preview
   (assets/spark-word-preview.js) — clearly labelled, nothing is saved.
   ============================================================ */
window.SPARK_WORD_CONFIG = {
  supabaseUrl: "",        // e.g. "https://abcdefghijklmnop.supabase.co"
  supabaseAnonKey: "",    // e.g. "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...."

  // Public origin of the site, used for share links and the magic-link
  // redirect. Leave empty to use the current origin.
  siteUrl: "",

  // "path"  → https://site/spark-word/014      (vercel.json / _redirects handle it)
  // "query" → https://site/index.html?issue=14  (works on any static host)
  urlStyle: "path",

  // Optional analytics bridge. Every event also goes to window.dataLayer
  // (GTM/GA4) and fires a `spark-word:analytics` CustomEvent on window.
  // analytics: function (eventName, props) { gtag("event", eventName, props); }
  analytics: null
};
