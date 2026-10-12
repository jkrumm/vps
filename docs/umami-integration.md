# Integrating Umami on a New Website

### Embed snippet

The Umami dashboard shows `script.js` in its tracking code UI — **ignore it**. The actual script path is renamed to bypass ad blockers. Always use:

```html
<script defer src="https://umami.jkrumm.com/p.js" data-website-id="<website-id>"></script>
```

Get `data-website-id` from the Umami dashboard (Settings → Websites → your site).

### Why `/p.js` and not `/script.js`

`TRACKER_SCRIPT_NAME=p.js` and `COLLECT_API_ENDPOINT=/api/p` are set in `compose.monitoring.yml`. This renames both endpoints so they don't match ad blocker filter lists (uBlock, Helium, etc.), which target known paths like `/script.js` and `/api/send`.

Checked 2026-10-12 against EasyPrivacy, uBO filters/privacy and Brave's own list: the only rule
that hits this instance is `||umami.*/script.js|$script` — `p.js`, `/api/p`, `recorder.js` and
`/api/record` match nothing, so direct loading survives Brave's default Shields. The residual risk
is a broader `umami.*` hostname rule.

### Same-origin proxy (first-party, blocker-proof)

Proxy the tracker through the site's own domain. Both `p.js` and `recorder.js` derive their
endpoint host from their own `src`, so loading them from `/u/` makes them post to `/u/api/p`
and `/u/api/record` — no `data-host-url` needed. Proxy exactly these paths (never a wildcard
onto `/api/*`):

```
/u/p.js                               → https://umami.jkrumm.com/p.js
/u/api/p                              → https://umami.jkrumm.com/api/p
/u/recorder.js                        → https://umami.jkrumm.com/recorder.js            (replays)
/u/api/record                         → https://umami.jkrumm.com/api/record             (replays)
/u/api/websites/<id>/recorder         → https://umami.jkrumm.com/api/websites/<id>/recorder
```

**Client IP.** Behind a proxy, Cloudflare's `cf-connecting-ip` is the proxy's IP. Umami reads
`CLIENT_IP_HEADER` first when present and falls back to its default chain otherwise, so
directly-loading sites are unaffected. It is set to Netlify's `x-nf-client-connection-ip`
(verified to reach proxy targets) and `SKIP_LOCATION_HEADERS=1` takes geo from the bundled
GeoLite2 DB instead of `cf-ipcountry`. Another proxy host (Vercel, nginx) must forward the
visitor IP in that same header — or the variable needs to change.

Reference implementation: sy-serendipity (`public/_redirects`, `src/util/analytics.ts`).
