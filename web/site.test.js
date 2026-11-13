// Checks on the deployable site: security headers and no secrets in shipped files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const WEB = new URL(".", import.meta.url).pathname;
const SUPABASE_URL = "https://pnkrlpvpqakqlwymybpj.supabase.co";

function allFiles(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    if (n.endsWith(".test.js")) return [];
    return statSync(p).isDirectory() ? allFiles(p) : [p];
  });
}

test("vercel.json sets a strict CSP limited to our Supabase project", () => {
  const cfg = JSON.parse(readFileSync(join(WEB, "vercel.json"), "utf8"));
  const headers = cfg.headers.find((h) => h.source === "/(.*)").headers;
  const csp = headers.find((h) => h.key === "Content-Security-Policy").value;
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /script-src 'self' https:\/\/cdn\.jsdelivr\.net https:\/\/cdnjs\.cloudflare\.com(;|$)/);
  assert.ok(csp.includes(`connect-src 'self' ${SUPABASE_URL}`));
  assert.match(csp, /frame-ancestors 'none'/);
  for (const k of ["X-Content-Type-Options", "Referrer-Policy", "Permissions-Policy"]) {
    assert.ok(headers.some((h) => h.key === k), `${k} missing`);
  }
});

test("no inline scripts (the CSP would block them)", () => {
  for (const f of allFiles(WEB).filter((f) => f.endsWith(".html"))) {
    const html = readFileSync(f, "utf8");
    for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)) {
      assert.ok(/\bsrc=/.test(m[1]) && m[2].trim() === "", `inline script in ${f}`);
    }
  }
});

test("no secrets in shipped files", () => {
  for (const f of allFiles(WEB)) {
    const text = readFileSync(f, "utf8");
    assert.ok(!/service_role|sb_secret_|GARMIN_PERSONAL_API_KEY\s*=/.test(text), `secret-like text in ${f}`);
    assert.ok(!/eyJhbGciOi[A-Za-z0-9_-]{20,}/.test(text), `JWT-looking key in ${f}`);
  }
});

test("every app page requires a session, except sign-in", () => {
  for (const f of allFiles(WEB).filter((f) => f.endsWith(".html") && !f.endsWith("signin.html"))) {
    assert.match(readFileSync(f, "utf8"), /app\/guard\.js/, `${f} does not load the session guard`);
  }
});
