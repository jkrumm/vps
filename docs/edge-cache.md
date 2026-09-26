# Edge Cache — Cloudflare cache rules for static RollHook sites

The reusable pattern for putting a static Astro (or any static-output) site
behind Cloudflare's edge cache, deployed on purge. First adopter: `jkrumm-com`
(`apps/jkrumm-com/`). `basalt-ui-marketing` and `rollhook-marketing` are on the
list to adopt this next — neither has a Cache Rule or purge-on-deploy yet.

This is a caching pattern for **whole-page HTML sites**, distinct from
`docs/image-cdn.md`, which covers imgproxy's derivative-image caching
(content-hashed URLs, no purge, no per-hostname rule).

---

## Header contract (set by the image's nginx, not Cloudflare)

Cloudflare doesn't cache HTML by default. This pattern makes every per-path
caching decision at the **origin**, via response headers, so the Cache Rule
itself is identical for every site:

| Path | `Cache-Control` (browser) | `Cloudflare-CDN-Cache-Control` (edge) |
|-|-|-|
| HTML, `.rss`/`.xml`/sitemap, `.txt` | `public, max-age=0, must-revalidate` | `max-age=31536000` |
| `/_astro/*` (content-hashed build output) | `public, max-age=31536000, immutable` | — (already covered by browser TTL) |
| other public files | `public, max-age=3600` | `max-age=31536000` |
| 404, trailing-slash 301 | none | none — Cloudflare's short default status TTLs apply |

**Why the split header:** Cloudflare's cache-control precedence is
`Cloudflare-CDN-Cache-Control` > `CDN-Cache-Control` > `Cache-Control`
([developers.cloudflare.com/cache/concepts/cdn-cache-control](https://developers.cloudflare.com/cache/concepts/cdn-cache-control/)).
`Cloudflare-CDN-Cache-Control` is consumed at the edge and **stripped before
the response reaches the browser** — so HTML can be cached for a year at the
edge (safe, because every deploy purges the hostname) while the browser still
revalidates on every navigation (`max-age=0`). Content-hashed assets don't
need the split: a changed file is a new URL, so a year is correct for both
tiers.

**Compression:** the origin does not compress. Cloudflare compresses at the
edge (zstd/br) on the way out — the origin is served once per Cache Rule TTL
window (effectively ~never hit once warm) and doesn't need a compression
story of its own.

### Canonical nginx config

Copied verbatim from `jkrumm.com`'s `deploy/nginx.conf` — the reference
implementation every adopter starts from:

```nginx
# Origin for jkrumm.com behind Cloudflare. The cache headers here are the whole
# edge-cache policy — the Cloudflare Cache Rule only makes HTML eligible and
# defers to them. Pattern: vps/docs/edge-cache.md.
#
# Browser vs edge are separate clocks:
#   Cache-Control                  → browsers (and Cloudflare, absent the below)
#   Cloudflare-CDN-Cache-Control   → Cloudflare only, highest precedence, stripped
#                                    before the response reaches the browser
# Every deploy purges the hostname, so a year at the edge is never stale.

map $sent_http_content_type $browser_cache {
    # Unhashed documents, feeds and code/data (e.g. a search index) revalidate
    # on every use — the edge answers the 304, so it stays cheap.
    ~^text/html                         "public, max-age=0, must-revalidate";
    ~^(application|text)/xml            "public, max-age=0, must-revalidate";
    ~^application/(rss|atom)\+xml       "public, max-age=0, must-revalidate";
    ~^application/(manifest\+)?json     "public, max-age=0, must-revalidate";
    ~^(application|text)/javascript     "public, max-age=0, must-revalidate";
    ~^text/(css|plain)                  "public, max-age=0, must-revalidate";
    # Unhashed media (favicon, og image): an hour of staleness is fine.
    default                             "public, max-age=3600";
}

server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;

    server_tokens off;
    # Redirects stay relative — the container never knows it sits behind TLS.
    absolute_redirect off;

    # trailingSlash: 'never' — /blog/ is a duplicate of /blog, never a page.
    rewrite ^/(.+)/$ /$1 permanent;

    # Content-hashed build output: a changed file is a new URL.
    location /_astro/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    # Directory-format build (blog/foo/index.html) served without a trailing
    # slash. Never `$uri/` here: it makes nginx 301 back to the slashed URL.
    location / {
        try_files $uri $uri/index.html =404;
        add_header Cache-Control $browser_cache;
        add_header Cloudflare-CDN-Cache-Control "max-age=31536000";
    }
}
```

**The `map` block is the content-type policy** — it decides the *browser*
`Cache-Control` per response, keyed on `$sent_http_content_type` (nginx's own
MIME guess from the file extension, so no extra config needed per file type):

- **Unhashed HTML, XML/RSS/Atom, JSON, JS, CSS** → `max-age=0, must-revalidate`.
  These are served under stable paths (`/`, `/blog`, `/sitemap.xml`,
  `/rss.xml`) whose content can change on the next deploy — the browser must
  always re-ask. The `Cloudflare-CDN-Cache-Control` header on the `location /`
  block still lets the *edge* hold these for a year, purged on deploy.
- **Unhashed media** (favicon, `og.png`, anything else with no build hash in
  its filename) → `max-age=3600`. An hour of staleness is an acceptable
  tradeoff for assets that rarely change and aren't purge-critical.
- **`/_astro/*`** (Astro's content-hashed build output) → `max-age=31536000,
  immutable`, no split header needed: a changed file is a *new* URL, so a
  year is correct for both browser and edge simultaneously.

**Two per-site knobs, adjust when adopting this for another site:**

- `rewrite ^/(.+)/$ /$1 permanent;` — only for an Astro build with
  `trailingSlash: 'never'`. Drop it (or invert it) for a site configured the
  other way; getting this wrong 301-loops or fights the framework's own
  canonical-URL logic.
- `error_page 404 /404.html;` — add this when the site ships a custom
  `404.html` in its build output. **Never add an SPA-style
  `try_files $uri $uri/index.html /index.html;` fallback** — that serves the
  homepage for every unmatched path with a `200`, and since the edge caches
  HTML for a year, one bad link would get the homepage cached under every
  junk URL that ever 404s until the next purge.

---

## One Cache Rule per hostname

Cloudflare doesn't cache HTML by default — the origin headers above make
every per-path decision, so **the rule itself never varies** between sites:

- Expression: `(http.host eq "<host>")`
- Eligible for cache: yes
- Edge TTL: respect origin (use cache-control header if present)
- Browser TTL: respect origin

Free plan allows 10 Cache Rules per zone. Create via the global `/cloudflare`
skill (Cache Rules section).

---

## Purge on deploy

Never `purge_everything` — the `jkrumm.com` zone also fronts the imgproxy
image CDN (`docs/image-cdn.md`); a full purge would cold every derivative URL
too. Purge by hostname instead, scoped to the site that just deployed.

Wire `jkrumm/rollhook-action@v1` into the deploy workflow, after RollHook
reports the rollout succeeded:

```yaml
- uses: jkrumm/rollhook-action@v1
  with:
    url: https://rollhook.jkrumm.com
    image_name: jkrumm-com
    cloudflare_purge_hosts: jkrumm.com   # multiline, one host per line
    cloudflare_api_token: ${{ secrets.CLOUDFLARE_PURGE_TOKEN }}
```

Purge only hosts that serve content — `www.` is a Traefik 301 to the apex and
isn't matched by the Cache Rule. The action resolves each host's zone itself
(Zone:Read), so no zone ID lives in the workflow.

Token: a dedicated Cloudflare API token, scoped to **Zone:Read + Cache
Purge** only (never account-wide, never edit permissions). Stored at
`op://common/cloudflare/CACHE_PURGE_TOKEN`, set as a repo secret:

```bash
# Read on the VPS (its 1Password service account holds common/) and piped
# straight into gh — never printed, never in the mini's headless cache.
ssh vps "op read 'op://common/cloudflare/CACHE_PURGE_TOKEN'" \
  | gh secret set CLOUDFLARE_PURGE_TOKEN --repo jkrumm/jkrumm.com
```

## Scheduled rebuilds also purge

A scheduled rebuild (`jkrumm.com`: daily, to refresh the build-time GitHub
heatmap) is a `schedule:` trigger on the **same** deploy workflow, so it
purges like any push. A rebuild path that skips the purge would leave the
edge serving the pre-rebuild HTML for up to a year. **GitHub pauses `schedule:`
workflows after 60 days of repo inactivity** — a push resumes them; a
silently-stale cron is a known failure mode to check for on quiet repos.

---

## Verify

```bash
curl -sI https://<host>/ | grep -i cf-cache-status   # MISS
curl -sI https://<host>/ | grep -i cf-cache-status   # HIT (repeat)
```

After a deploy (purge fired), the same request should go back to `MISS`.

`make edge-cache-status HOST=<host>` runs this (and every other check below)
in one shot.

---

## The `edge-cache.py` tool

`scripts/edge-cache.py` (stdlib-only Python, no dependency) replaces the old
copy-paste API snippets in the `/cloudflare` skill for this one pattern.
Both make targets are prod-only and go through `$(OP_RUN)`, so secrets come
from `.env.tpl` (`CLOUDFLARE_MANAGE_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_TUNNEL_ID`) — never printed, and no zone/tunnel/account ID is
ever printed either.

```bash
make edge-cache-status HOST=example.com              # read-only checklist, exits 1 on any ✗
make edge-cache-apply  HOST=example.com               # idempotent: DNS, ingress, Cache Rule, then status
make edge-cache-apply  HOST=example.com DRY_RUN=1      # preview the same, writes nothing
```

`status` walks five checks, each printed as ✓/✗ with a one-line fix hint:
zone lookup, proxied CNAME (HOST + a warn-only check for `www.HOST`), tunnel
ingress coverage (explicit entry or a covering wildcard — `*.x` never
matches `x` itself — for both HOST and `www.HOST`), the `edge-cache HOST`
Cache Rule, and a live probe of `https://HOST/` (200, split cache headers,
second-request `HIT`, plus the first `/_astro/*.css|js` asset found in the
HTML checked for `immutable` + `HIT`).

`apply` is additive and idempotent: it only ever creates a CNAME that's
missing (an existing record pointing elsewhere is a hard stop, never
overwritten), only inserts ingress entries not already covered, and upserts
the Cache Rule by `description` while preserving every other rule/entry/record.

---

## Adoption checklist for another site

1. Copy the canonical nginx config above into the image's origin, adjusting
   the two per-site knobs (trailing-slash rewrite, `404.html`).
2. Add `cloudflare_purge_hosts: <host>` +
   `cloudflare_api_token: ${{ secrets.CLOUDFLARE_PURGE_TOKEN }}` to the
   `jkrumm/rollhook-action@v1` step. Scheduled rebuilds: `schedule:` on that
   same workflow, never a second one.
3. Set the repo secret (never printed, never in the mini's cache):
   ```bash
   ssh vps "op read 'op://common/cloudflare/CACHE_PURGE_TOKEN'" \
     | gh secret set CLOUDFLARE_PURGE_TOKEN --repo jkrumm/<repo>
   ```
4. Deploy, and confirm the origin headers are live
   (`curl -sI https://<host>/ | grep -i cache-control`).
5. `make edge-cache-apply HOST=<host>` (`DRY_RUN=1` to preview) — CNAMEs,
   ingress, Cache Rule, then the status checklist. **After** step 4: a Cache
   Rule over an origin that sends no `Cache-Control` falls back to
   Cloudflare's default TTL and caches HTML nothing will purge.
6. `make edge-cache-status HOST=<host>` any time — all ✓ means done.

---

## Troubleshooting

| Symptom | Likely cause |
|-|-|
| Bodiless `404` with `cf-cache-status: DYNAMIC` | Missing tunnel ingress entry for an apex/other-zone host — a wildcard never matches its own apex |
| `DYNAMIC` on an HTML request that should be cacheable | No Cache Rule for the host (or it's disabled/mismatched) |
| `cf-cache-status` never reaches `HIT` | Origin is sending `no-store`/`private`, or a `Set-Cookie` header — both make Cloudflare bypass cache regardless of the Cache Rule |
| Stale content right after a deploy | The purge step failed — check the `rollhook-action` step's summary in the GitHub Actions run |
| `10000` authentication error right after a token permission edit | Cloudflare's permission propagation lag — wait a few minutes and retry |
