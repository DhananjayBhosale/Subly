// Serves subly.dhananjaytech.app. The page and its images come straight from the
// repository's main branch, so the site updates when site/index.html changes.
const PAGE_URL = "https://raw.githubusercontent.com/DhananjayBhosale/Subly/main/site/index.html";
const DMG_URL = "https://github.com/DhananjayBhosale/Subly/releases/latest/download/Subly.dmg";
const IMAGE_BASE = "https://raw.githubusercontent.com/DhananjayBhosale/Subly/main/docs/images/";
const IMAGE_NAME = /^[a-z0-9-]+\.(png|gif|jpg)$/;
const IMAGE_TYPES = { png: "image/png", gif: "image/gif", jpg: "image/jpeg" };

// Only the page's own inline scripts may run: their hashes are worked out from the
// page as served, so nothing injected or added elsewhere can execute.
function csp(scriptSources = "'none'") {
  return "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline' https://fonts.bunny.net; " +
    `font-src https://fonts.bunny.net; script-src ${scriptSources}; ` +
    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
}

const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
  "Content-Security-Policy": csp(),
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};

async function scriptHashes(html) {
  const hashes = [];
  for (const m of html.matchAll(/<script(?![^>]*\btype=["']application\/ld\+json)[^>]*>([\s\S]*?)<\/script>/gi)) {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(m[1])));
    hashes.push(`'sha256-${btoa(String.fromCharCode(...digest))}'`);
  }
  return hashes.length ? hashes.join(" ") : "'none'";
}

// A network error from GitHub must still end in a page, not an exception.
async function fetchUpstream(url, ttl) {
  try {
    const res = await fetch(url, { cf: { cacheTtl: ttl, cacheEverything: true } });
    return res.ok ? res : null;
  } catch {
    return null;
  }
}

const NOT_FOUND_HTML = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Not found · Subly</title><style>:root{color-scheme:light dark}body{margin:0;min-height:100vh;display:grid;place-items:center;font:17px/1.5 -apple-system,BlinkMacSystemFont,Inter,sans-serif;text-align:center;padding:16px}a{color:#0a84ff}</style><main><h1>Page not found</h1><p><a href="/">Go to the Subly home page</a></p></main></html>`;

const FALLBACK_HTML = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Subly</title><style>:root{color-scheme:light dark}body{margin:0;min-height:100vh;display:grid;place-items:center;font:17px/1.5 -apple-system,BlinkMacSystemFont,Inter,sans-serif;text-align:center;padding:16px}a{color:#0a84ff}</style><main><h1>Subly</h1><p>Captions for your videos, made on your Mac.</p><p><a href="${DMG_URL}">Download for Mac</a> · <a href="https://github.com/DhananjayBhosale/Subly">Open source on GitHub</a></p></main></html>`;

function respond(body, status, headers) {
  return new Response(body, { status, headers: { ...SECURITY_HEADERS, ...headers } });
}

export default {
  async fetch(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return respond("Method not allowed", 405, { Allow: "GET, HEAD", "Content-Type": "text/plain; charset=utf-8" });
    }

    const { pathname } = new URL(request.url);

    if (pathname === "/" || pathname === "/index.html") {
      const upstream = await fetchUpstream(PAGE_URL, 300);
      if (upstream) {
        const html = await upstream.text();
        return respond(request.method === "HEAD" ? null : html, 200, {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "public, max-age=300",
          "Content-Security-Policy": csp(await scriptHashes(html)),
        });
      }
      return respond(FALLBACK_HTML, 503, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    }

    if (pathname === "/download") {
      return respond(null, 302, { Location: DMG_URL, "Cache-Control": "no-store" });
    }

    if (pathname === "/favicon.ico") {
      return respond(null, 301, { Location: "/images/icon.png" });
    }

    if (pathname.startsWith("/images/")) {
      const name = pathname.slice("/images/".length);
      const match = IMAGE_NAME.exec(name);
      if (match) {
        const upstream = await fetchUpstream(IMAGE_BASE + name, 86400);
        if (upstream) {
          return respond(request.method === "HEAD" ? null : upstream.body, 200, {
            "Content-Type": IMAGE_TYPES[match[1]],
            "Cache-Control": "public, max-age=86400",
          });
        }
      }
    }

    return respond(request.method === "HEAD" ? null : NOT_FOUND_HTML, 404, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=300",
    });
  },
};
