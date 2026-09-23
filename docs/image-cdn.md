# Image CDN — imgproxy + B2 + Cloudflare

The image serving substrate. The `img/` prefix of the existing
private object-storage bucket holds originals; imgproxy on the VPS renders
resized/reformatted derivatives on demand; Cloudflare's edge caches those
derivatives. Consumers: the static photo-gallery site, blog/articles, the
Obsidian vault, and agents.

`image-share` (homelab) is the layer that consumes this substrate for
sharing/publishing; `shutterflow` is a separate, unrelated MacBook photography
app and does not touch this CDN.

```
client → Cloudflare edge (cache) → tunnel → Traefik → imgproxy → B2 img/ (private)
```

**This doc covers the CDN substrate only.** The image lives in a layered
delivery chain: local truth (files on disk) → `image-share` (a bearer-auth'd
service on the homelab; **share** = local → private, **publish** = private →
public, and `publish` always stages a durable homelab copy before anything
reaches this CDN) → the CDN documented here. The agent door into that whole
chain is the `/img` skill (`dotfiles`); the private layer's own contract —
schema, endpoints, key model — lives in image-share's `docs/design.md`. Don't
duplicate that design here; this doc stays scoped to imgproxy/B2/Cloudflare.

---

## The bucket is shared with backups — read this first

`img/` lives in the **same bucket as the database backups** (`backups/vps/postgres/`,
`backups/vps/mariadb/`, …). imgproxy is public and unauthenticated. The only thing
standing between an anonymous request and a Postgres dump is the credential scope:

> **The imgproxy B2 application key MUST be created with `--name-prefix img/`.**
> B2 enforces that server-side. A key scoped this way returns 401 for
> `backups/…` no matter what URL reaches imgproxy.

`IMGPROXY_S3_ALLOWED_BUCKETS` does **not** help here — `backups/` is in the same
bucket it allows. `IMGPROXY_ALLOWED_SOURCES=s3://<bucket>/img/` is a real second
layer, but it is imgproxy-side config, not a credential boundary. Treat the
name-prefix as the control and the rest as defence in depth.

Never point imgproxy at `op://common/backblaze-s3/*` — that credential is
bucket-wide with `writeFiles`, and exists for the backup scripts.

---

## Access model

URLs are **unsigned**. imgproxy runs without `IMGPROXY_KEY`/`IMGPROXY_SALT`.

```
https://img.<domain>/_/rs:fit:800/plain/img://fuji/foo.jpg
                    │ │           │     │
                    │ │           │     └─ img:// alias → s3://<bucket>/img/
                    │ │           └─ plain (unencoded) source URL follows
                    │ └─ processing options (omit entirely for the original)
                    └─ signature slot
```

**The signature slot accepts any string in unsigned mode** — `_`, `unsafe`,
`insecure` all work; it is not a keyword. Once `IMGPROXY_KEY`/`IMGPROXY_SALT`
are set it must hold a valid HMAC, and every placeholder stops working.

**`img://` is an alias**, not a real scheme — `IMGPROXY_URL_REPLACEMENTS` expands
it to `s3://<bucket>/img/` before anything else runs. Public URLs therefore leak
neither the bucket name nor the `img/` prefix. The long form
(`plain/s3://<bucket>/img/…`) still works and is equivalent.

Anyone who knows an object key can render it — unsigned URLs are the permanent design, not a placeholder.

| Control | What it prevents |
|-|-|
| B2 key `--name-prefix img/` | reading `backups/` or anything else in the bucket (server-side, authoritative) |
| S3 keys are literal — no `..` resolution | `img://../backups/…` traversal out of the alias (verified, see results) |
| B2 key read-only caps | imgproxy writing or deleting anything, ever |
| `IMGPROXY_ALLOWED_SOURCES=s3://<bucket>/img/` | imgproxy being used as an open proxy for arbitrary URLs |
| `IMGPROXY_S3_ALLOWED_BUCKETS` | reaching a *different* bucket in the account |
| `IMGPROXY_ALLOW_PRIVATE_SOURCE_ADDRESSES=false` | SSRF into the internal Docker/Tailscale networks |
| Non-enumerable object keys | discovery of anything not meant to be public |

The bucket stays **private** — B2 never serves it directly, only imgproxy reads
from it.

**Staying unsigned is a permanent decision, not a deferred upgrade.** Every
published URL — vault embeds, jkrumm.com articles, `imgcli` output, image-share's
`cdnUrl` responses — is an unsigned literal baked into whatever it was pasted
into. Flipping `IMGPROXY_KEY`/`IMGPROXY_SALT` would invalidate all of them at
once, with no way to retrofit a signature into already-published text. The
access model is, and stays, the private bucket + the prefix-locked read-only
key + non-enumerable opaque names under `img/gen/` and `img/misc/`. Don't
budget for a signed-URL migration; it isn't planned.

---

## Prefix layout (convention, not enforced)

Everything lives under `img/`. Below that, nothing in the config restricts
prefixes — this is a documented convention so the bucket stays navigable.

| Prefix | Contents | Naming |
|-|-|-|
| `img/fuji/` | curated camera exports | readable paths OK (`img/fuji/2026-portugal/DSCF1234.jpg`) |
| `img/blog/` | article images | readable paths OK |
| `img/gen/` | generated / AI / ad-hoc | non-guessable (hash or nanoid) |
| `img/misc/` | everything else | non-guessable |

Readable paths are only appropriate where the content is meant to be
discoverable anyway. Anything sensitive goes under a non-guessable name,
because unsigned URLs mean the key *is* the access control.

---

## Cloudflare caching — and the `Vary` caveat

`IMGPROXY_TTL=31536000` emits `Cache-Control: max-age=31536000`, which
Cloudflare's default static caching honours. Derivative URLs are immutable (the
processing options are in the path), so a year is correct.

**The caveat:** imgproxy sets `Vary: Accept` when `IMGPROXY_AUTO_WEBP` /
`IMGPROXY_AUTO_AVIF` are on, but **Cloudflare ignores `Vary` on non-Enterprise
plans for everything except `Accept-Encoding`**. So the first client to request a
given URL determines the cached format for every subsequent client. If an
AVIF-capable browser warms the cache, an AVIF response is what an
AVIF-incapable client gets too.

**Confirmed live**, not theoretical: a request sending `Accept: image/webp,image/*`
(no AVIF) was served `image/avif` from the edge, because an AVIF-capable client
had warmed that URL first.

In practice this is low-risk in 2026 — every current browser engine supports
AVIF. It matters for:

- old Safari (< 16.4) and other stale clients
- scrapers, RSS readers, and social/OpenGraph link unfurlers, which often send
  a generic or absent `Accept`

**Mitigation where it matters — use `f:jpg`, NOT `@jpg`:**

```
.../rs:fit:800/f:jpg/plain/img://blog/x.jpg      ✅ pinned AND cached
.../rs:fit:800/plain/img://blog/x.jpg@jpg        ❌ pinned, NOT cached
```

Both pin the output format. But Cloudflare's default static caching keys off the
**URL's trailing extension**, and the `@jpg` form ends the path in `.jpg@jpg`,
which Cloudflare does not recognise — measured `cf-cache-status: DYNAMIC` on
every repeat request, i.e. every hit goes to origin. The `f:jpg` processing
option leaves the path ending in `.jpg`, and measured `MISS` → `HIT`.

Use `f:jpg` for OpenGraph/RSS/email images; use auto-negotiation for in-page
`<img>` tags.

Do not add a Cloudflare cache rule unless verification actually shows repeat
`MISS`es — the default static-asset caching covers this given the headers above.
(Whole-page HTML sites, which Cloudflare does *not* cache by default, use a
per-hostname Cache Rule instead — `docs/edge-cache.md`.)

---

## Provisioning the B2 keys

Creating application keys requires the `writeKeys` capability, which only the
**account master key** at `op://Private/b2-master` holds. Bucket-restricted keys
cannot create keys — B2 returns `unauthorized`.

B2 account key inventory:

| Key | Scope | Stored at | Used by |
|-|-|-|-|
| account master | all buckets, incl. `writeKeys` | `op://Private/b2-master` | key management only — never wire into automation |
| `b2-admin-jkrumm` | bucket `jkrumm`, incl. `deleteFiles` | `op://Private/Backblaze B2` (`MASTER_*` fields) | homelab `make restic-prune` / `restic-init` |
| `b2-shared-append-only` | bucket `jkrumm`, no delete | `op://common/backblaze-s3` | backup scripts (vps pg/mariadb, homelab restic) |
| `imgproxy-read` | bucket `jkrumm`, **prefix `img/`**, read-only | `op://vps/imgproxy` | imgproxy |
| `images-write` | bucket `jkrumm`, **prefix `img/`**, write, no delete | `op://common/b2-images-write` | `imgcli sync` (legacy bulk mirror lane) plus `imgcli ls`/`info`/`url` (read-only) and `publish`'s `CDN_BASE` lookup — `imgcli upload` and all agent/Obsidian uploads now go through image-share's API instead |
| `image-share-b2` | bucket `jkrumm`, **prefix `img/`**, `listFiles`/`readFiles`/`writeFiles`/`deleteFiles` | `op://homelab/image-share/{B2_KEY_ID,B2_APP_KEY}` | the image-share service on the homelab — the sole delete-capable key ever wired into automation |

> The `MASTER_*` field names in `op://Private/Backblaze B2` are historical and
> **do not hold the master key** — they hold `b2-admin-jkrumm`. The names are
> load-bearing: `homelab/Makefile` reads them literally. Do not rename them
> without updating that Makefile.

To create the imgproxy keys from scratch:

```bash
b2 account authorize "$(op read 'op://Private/b2-master/B2_KEY_ID' --account tkrumm)" \
                     "$(op read 'op://Private/b2-master/B2_APP_KEY' --account tkrumm)"

b2 key create --bucket <bucket> --name-prefix img/ \
  imgproxy-read listBuckets,listFiles,readFiles

b2 key create --bucket <bucket> --name-prefix img/ \
  images-write listBuckets,listFiles,readFiles,writeFiles

b2 account clear
```

Neither gets `deleteFiles` — uploads must not be able to destroy originals, and
the CDN must not be able to write at all.

**Deletion is not impossible, though — it's scoped and gated.** The dedicated
`image-share-b2` key (see the inventory above) carries `deleteFiles`, and it is
reachable only through image-share's `DELETE /api/b2/:key` (bearer-auth'd,
traversal-guarded on the decoded key). No agent machine and no other credential
in this repo holds delete capability — the read-only and no-delete keys above
are the norm, not a gap.

B2 has a lifecycle rule on `img/`: hidden (overwritten or deleted) versions are
purged after 30 days. Deletes and overwrites through `image-share-b2` no longer
accrete invisible version debris in the bucket.

> **Capture the output in the same command that stores it.** B2 prints the
> `applicationKey` exactly once; a create whose secret you don't persist leaves
> an orphaned key you can only delete and redo.

B2 prints the application key exactly once, at creation. Capture both into
1Password immediately. Bucket coordinates (`BUCKET`, `ENDPOINT`, `REGION`) are
reused from the existing `op://common/backblaze-s3` item — no new fields needed
beyond `REGION`.

**Verify the prefix restriction actually took** before deploying:

```bash
b2 account authorize <imgproxy-read-id> <imgproxy-read-key>
b2 file download b2://<bucket>/backups/vps/postgres/<any-file> /tmp/x  # must FAIL
b2 ls b2://<bucket>/img/                                               # must succeed
b2 account clear
```

---

## Observability

imgproxy exports traces, metrics, and logs to ClickStack over `monitoring-net`
(wiring and the enable-flag gotcha: `docs/observability.md`). Traefik's edge span
alone can't tell you *why* a render was slow; imgproxy's spans nest underneath it
and split the request:

```sql
SELECT SpanName, count() c, round(avg(Duration)/1e6,2) avg_ms
FROM default.otel_traces
WHERE ServiceName='imgproxy' AND Timestamp > now() - INTERVAL 1 HOUR
GROUP BY SpanName ORDER BY c DESC
```

Measured at go-live, per origin request (cache-busted, so every one hit B2):

| span | avg | max |
|-|-|-|
| `/request` | 132.62 ms | 478.50 ms |
| `downloading_source_image` | 95.96 ms | 442.69 ms |
| `processing_image` | 42.08 ms | 51.18 ms |
| `queue` | 0.01 ms | 0.01 ms |

**Origin latency is dominated by the B2 fetch, not by libvips** — ~72% of the
request. Processing is stable (42–51 ms) while download swings by 10×. So the
lever for first-render latency is the source round-trip, not `IMGPROXY_WORKERS`
or CPU; and `queue` at 0.01 ms says there is no worker contention to tune away.
Edge caching hides all of this from repeat requests, which is why the Cloudflare
`HIT` rate matters more than any imgproxy setting here.

---

## Deploy

```bash
# only after op://vps/imgproxy/* exists — every `make` target on the VPS
# resolves the whole .env.tpl, so an unresolvable ref breaks all of them
git push && ssh vps "cd ~/vps && git pull && make imgproxy-up ENV=prod"
```

Then add the DNS record via the `/cloudflare` skill: `img.<domain>` → CNAME to
the tunnel, **proxied (orange cloud)** so edge caching applies. The wildcard
tunnel ingress (`*.<domain>` → `https://traefik:443`) already routes it — no
tunnel config change needed.

---

## Verification

A 2000×2000 smoke-test object is **already staged** at
`img/misc/cdn-smoke-test.jpg` (uploaded with the admin key while provisioning,
since `images-write` did not exist yet). `rs:fit:800` against it should return
800×800. Re-run step 1 with the real write key once it exists, to confirm that
key works too.

```bash
# 1. upload a test image with the WRITE key
aws s3 cp test.jpg s3://<bucket>/img/misc/cdn-smoke-test.jpg \
  --endpoint-url <endpoint>

# 2. resized rendition, auto-format
curl -sI -H 'Accept: image/avif,image/webp,image/*' \
  'https://img.<domain>/_/rs:fit:800/plain/img://misc/cdn-smoke-test.jpg'
#    → 200, content-type: image/avif (or image/webp)

# 3. repeat → edge cache hit
#    → cf-cache-status: HIT

# 4. source lock — off-bucket source must be rejected
curl -so /dev/null -w '%{http_code}\n' \
  'https://img.<domain>/_/rs:fit:800/plain/https://example.com/x.jpg'
#    → 404 (imgproxy reports a forbidden source as 404, not 403)

# 5. THE IMPORTANT ONE — backups must be unreachable through the CDN
curl -so /dev/null -w '%{http_code}\n' \
  'https://img.<domain>/_/rs:fit:800/plain/s3://<bucket>/backups/vps/postgres/<file>'
#    → 404

# 6. traversal out of the img:// alias must not reach backups either
curl -so /dev/null -w '%{http_code}\n' \
  'https://img.<domain>/_/plain/img://../backups/vps/postgres/<file>'
#    → 404
```

Step 5 is the one that matters given the shared bucket. Re-run it after any
change to the key, `ALLOWED_SOURCES`, or the bucket layout.

### Results at go-live (2026-07-21)

| Check | Result |
|-|-|
| `rs:fit:800` on a 2000×2000 source | 200, 800×800, `image/avif` |
| `cache-control` | `public, max-age=31536000` |
| Repeat request | `cf-cache-status: HIT` |
| Off-bucket source (`https://…`, other bucket) | 404 |
| `backups/…` real dump filename via CDN | 404 |
| `img://../backups/…` traversal (4 encodings) | 404 |
| B2 key listing `backups/` directly | `unauthorized` (server-side, `restricted to files that start with 'img/'`) |
| `f:jpg` | `image/jpeg`, MISS → HIT |
| Short form `/_/plain/img://…` | 200 (alias + placeholder slot both work) |
| `@jpg` | `image/jpeg`, `DYNAMIC` (uncached — see above) |

Confirm dimensions with `curl ... | file -` — `rs:fit:800` bounds the *longest*
side to 800, it does not force width.
