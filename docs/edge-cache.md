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

Reference implementation: `jkrumm.com`'s `deploy/nginx.conf` (see that repo).

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

---

## Adoption checklist for another site

1. Set the header contract above in the image's nginx (or equivalent origin).
2. Create the Cache Rule for the hostname via `/cloudflare` (expression, TTLs
   as above).
3. Add `jkrumm/rollhook-action@v1` with `cloudflare_purge_hosts` +
   `cloudflare_api_token: ${{ secrets.CLOUDFLARE_PURGE_TOKEN }}` to the deploy
   workflow, after the RollHook deploy step succeeds.
4. Scheduled rebuilds: add `schedule:` to that same workflow, never a second one.
5. `gh secret set CLOUDFLARE_PURGE_TOKEN` on the site's repo from
   `op://common/cloudflare/CACHE_PURGE_TOKEN`.
6. Verify: MISS → HIT → deploy → MISS again.
