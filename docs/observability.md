# Observability — ClickStack + OTLP

End-to-end OpenTelemetry tracing across Traefik, every VPS service, and
browser-side SPAs. The whole pipeline runs on this VPS — single instance of
`clickhouse/clickstack-all-in-one` (ClickHouse + OTel Collector + HyperDX UI +
MongoDB) at `clickstack`, exposed publicly only via Traefik on `hyperdx.${DOMAIN}`
(Tailscale-only) and `otel.${DOMAIN}` (browser OTLP ingest).

## Architecture

```
                                         ┌─────────────────────────────────┐
                                         │  clickstack container           │
                                         │                                 │
   Browser SDK (any app frontend)        │   ┌─────────────────────────┐   │
   ───────────────────────────────►      │   │ otlp/hyperdx receiver   │   │
   <app>.${DOMAIN}/v1/traces             │   │   :4317 grpc  AUTHED    │   │
   <app>.${DOMAIN}/v1/logs               │   │   :4318 http  AUTHED    │   │
   (or otel.${DOMAIN}/v1/...)            │   └────────────┬────────────┘   │
                                         │                ▼                │
                                         │       traces/logs/metrics       │
                                         │           pipelines             │
                                         │                ▲                │
   Traefik (own request spans)           │                │                │
   VPS-internal services                 │   ┌────────────┴────────────┐   │
   (docker monitoring-net only)          │   │ otlp/internal receiver  │   │
   ────────────────────────────────►     │   │   :4319 http  NO AUTH   │   │
   clickstack:4319                       │   │   (docker bridge only)  │   │
                                         │   └─────────────────────────┘   │
                                         └─────────────────────────────────┘
```

**Two-tier ingest, two trust boundaries:**

| Tier | Port | Auth | Trust boundary | Used by |
|-|-|-|-|-|
| Public | `:4318` (http) / `:4317` (grpc) | `bearertokenauth` | Public ingress via Traefik + ingestion key | Browser SDKs (any frontend), the Mac mini's services (argo-api, iris-server, agent-workflows, opencode) via `otel.<domain>` |
| Internal | `:4319` (http) | none | docker `monitoring-net` membership | Traefik, imgproxy, fpp-server, fpp-analytics, email-gateway, shutterflow-*, rollhook |

The `:4319` port has no host binding and no Traefik label — it's reachable only
from other containers on `monitoring-net`. The trust boundary is the docker
network.

## Why the two tiers exist — the bugs that forced it

Two stuck upstream issues prevent Traefik from sending an OTLP auth header
reliably:

1. **Traefik static YAML does not substitute `${VAR}` in header values.** Empirically
   verified: with `tracing.otlp.http.headers.authorization: "${HYPERDX_API_KEY}"`,
   Traefik's debug config dump shows the loaded header value as the literal string
   `${HYPERDX_API_KEY}`, not the substituted token. (Traefik's YAML loader has
   never supported shell-style interpolation; only the dynamic *file provider* supports
   Go-template `{{ env "X" }}`.)

2. **The env-var route for header maps is broken in Traefik 3.3–3.6.** Setting
   `TRAEFIK_TRACING_OTLP_HTTP_HEADERS_authorization=<token>` does not populate the
   headers map at all — the `headers` key is absent from the loaded static config.
   See [traefik-helm-chart#1361](https://github.com/traefik/traefik-helm-chart/issues/1361)
   — acknowledged as a bug, closed for inactivity, unfixed in 3.6.

Meanwhile, ClickStack's `:4318` receiver enforces `bearertokenauth/hyperdx` and
the base config is locked by OpAMP — no env var to disable it, no override
(only merge — see below). Inlining the token in `traefik.yml` was rejected
because the VPS repo is public on GitHub and the token wouldn't be rotatable
without a code edit.

**Resolution**: add a *second* unauthed receiver instance on `:4319` bound only to
the docker bridge. The trust boundary moves from "the bearer token" to "membership
in `monitoring-net`", which is acceptable for a single-host VPS where every container
is ours.

## Telemetry contract

Every service that sends telemetry to this ClickStack follows these rules. ClickHouse is the
single source of truth, so a name or value that differs between services cannot be queried
across them. The registry of who emits what is [`observability/services.yaml`](../observability/services.yaml);
a service that is not in it does not exist as far as dashboards and alerts are concerned.

| Attribute | Rule |
|-|-|
| `service.name` | `<product>-<role>` (`fpp-server`, `shutterflow-share`); a single-process product may use the bare product name. Must be listed in the registry. |
| `service.namespace` | The product, required (`free-planning-poker`, `shutterflow`; platform services of this repo use `vps`). |
| `service.version` | The short git SHA of the deployed build. Never `local`, `unknown` or `latest` in prod. A third-party image reports its own release. |
| `deployment.environment.name` | Exactly `prod` or `dev`. Not `production`, `development`, `staging` or `test`. The old key `deployment.environment` is deprecated (semantic conventions 1.45); the gateway keeps it in step, apps should stop sending it. |
| `host.name` | The machine: `vps`, `mini`, `homelab`, `home`, `macbook`. Never a container ID; that belongs in `container.id`. Browser and phone code leaves it unset. |
| Signals | Every service sends traces and OTLP logs, and every log record has a non-empty `Body`. |
| Custom metrics | Names are prefixed with the namespace (`fpp.room.count`). |

**Where each rule is enforced.** Apps set what they can; the ClickStack gateway corrects what
it can reach, so a violation does not reach the tables ("Gateway normalisation", below).

| Rule | App side | Gateway (`clickstack/otel-custom.yaml`) |
|-|-|-|
| environment | `OTEL_RESOURCE_ATTRIBUTES=...,deployment.environment.name=prod` in the service's compose env | `production`→`prod`, any other value besides `prod`/`dev` (`development`, `test`, `staging`, `latest`)→`dev` on both keys; missing `.name` copied from the old key |
| host | nothing | `:4319`: `host.name=vps`, a container-ID-looking value moves to `container.id`. Authed tier: the container ID moves to `container.id`, `host.name` is dropped |
| namespace, version | `OTEL_RESOURCE_ATTRIBUTES=service.namespace=<product>`; version baked at build | not touched (a wrong version is the app's bug) |

Set `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` in the compose env of a VPS service whose
SDK reads them (Node `NodeSDK`, Python `Resource.create`, Go SDKs, Traefik, email-gateway's own
parser). An app that builds its resource in code and ignores the variable (fpp-server,
rollhook, shutterflow-key-broker) is not patched around here: the violation is in the registry
`notes` and filed as a signal on its repo. Confirm after any change that rows actually carry
the attributes (see Verification commands); an SDK that ignores the variable fails silently.

## Telemetry lint

`make telemetry-lint` holds the registry (`observability/services.yaml`) and the contract above against what prod
ClickHouse actually received. The factory runs it as the project's hygiene probe (`project.yaml` →
`hygiene.probes`): any finding is a red probe, and the weekly pass files it as an Issue on the repo that owns the
service.

- **Reads.** Three read-only queries through `ssh vps` → `docker exec clickstack clickhouse-client` (Tailscale SSH, no
  1Password prompt on the mini). Each has a `LIMIT` and a time filter on the partition column (`TimestampTime` for
  `otel_logs` and `hyperdx_sessions`, `Timestamp` for `otel_traces`, `TimeUnix` for `otel_metrics_*`): 7 days for
  existence and silence, 24 hours for attributes, bodies and volume. The drift rule reads the HyperDX REST API with the
  agent key from `secrets-run` (offline cache) or `HYPERDX_PROD_ACCESS_KEY`. `TELEMETRY_LINT_SSH` replaces `ssh vps`.
- **Exit.** 0 clean; non-zero with one line per finding (rule, service, measured value, owning repo) and a summary table.
  The script itself exits 1 on findings and 2 when prod could not be read (a probe error, not a verdict); through
  `make` both show as 2.
- **Not Weaver.** OpenTelemetry Weaver (`registry check`, `live-check`) was considered and left out: at about 30
  services a SQL lint against live data covers the need without a schema toolchain.

| Rule | Finding when (last 24 h unless stated) |
|-|-|
| `unregistered` | a `service.name` emitted in 7 days that is not in the registry (add it in the change that makes it emit) |
| `silent` | a signal the registry expects has no rows for more than 24 h (or none in 7 d) |
| `environment` | `deployment.environment.name` is missing, not `prod`/`dev`, or differs from the registry's `env` |
| `namespace` | `service.namespace` is missing |
| `version` | `service.version` is missing or `local`, `dev`, `unknown`, `latest`, `0.0.0`, on a `prod` service |
| `host` | `host.name` is missing or a 12–64 character hex string (a container ID); skipped for registry `host: client` |
| `body-empty` | more than 1 % of a service's log records have an empty `Body` |
| `untraced-logs` | the share of logs without a `TraceId` is above `budget.untraced_logs` |
| `volume` | rows in 24 h of a signal are above `budget.<signal>` |
| `drift` | an alert or dashboard exists in prod but not in `observability/`, or the reverse (names compared; those tagged for another repo, `weatherorb` and `agw`, are left out as in `hyperdx-export`). Fix with `make hyperdx-export` or `make hyperdx-apply`, so it has no registry switch |

Retired registry entries are skipped by every rule. A violation shows for up to 24 h after its fix shipped, until the old rows
leave the window.

### Silencing a rule

Never edit the script. Say it in the service's registry entry:

| Field | Effect |
|-|-|
| `ignore: { <rule>: "<reason>" }` | that rule stays quiet for that service; the reason is required (a test checks the rule name and that a reason exists) |
| `expected: none` or `expected: [logs]` | which `signals` must not go silent; `none` for intermittent emitters (a job that logs once per deploy) and for services that by design emit nothing (`signals: []`) |
| `budget: { traces, logs, metrics, untraced_logs }` | rows per day per signal, and the largest untraced share (0–1). A key left out is no check, so a new service is unchecked until it has one |

Budgets were seeded on 2026-11-17 at 3× the 7-day daily average with a floor of 100 rows (`host-agent` and `host-probe`, deployed 2026-11-14, from the 24 h rate). `python3 scripts/telemetry-lint.py
--seed-budgets` prints the same numbers from live data for a new service. A budget that a real, wanted growth exceeds is
raised in the same change that causes the growth.

## ClickStack custom config — merge semantics

ClickStack supports merging a custom collector config:

```yaml
# compose.monitoring.yml — clickstack service
environment:
  CUSTOM_OTELCOL_CONFIG_FILE: /etc/otelcol-contrib/custom.config.yaml
volumes:
  - ./clickstack/otel-custom.yaml:/etc/otelcol-contrib/custom.config.yaml:ro
```

**Critical constraint**: the merge **cannot change the receivers or exporters** of the
pipelines ClickStack defines. Its OpAMP remote config is applied on top of the local files and
sets those two lists; the local files only supply the pipelines' `processors:`. Concretely,
this fails:

```yaml
# DOES NOT WORK — base `traces` pipeline keeps its original receivers list,
# this declaration is silently ignored.
service:
  pipelines:
    traces:
      receivers: [otlp/hyperdx, otlp/internal]
```

What does work: defining **parallel** pipelines that target the same downstream
exporters:

```yaml
# clickstack/otel-custom.yaml — applied form
receivers:
  otlp/internal:
    protocols:
      http:
        endpoint: 0.0.0.0:4319

service:
  pipelines:
    traces/internal:
      receivers: [otlp/internal]
      processors: [memory_limiter, batch]
      exporters: [clickhouse]
    logs/in-internal:
      receivers: [otlp/internal]
      exporters: [routing/logs]
    metrics/internal:
      receivers: [otlp/internal]
      processors: [memory_limiter, batch]
      exporters: [clickhouse]
```

**What does work on a base pipeline: `processors:`.** The base `config.yaml` declares the
`processors:` lists of `traces`, `metrics`, `logs/out-default` and `logs/out-rrweb`, and the remote config
deliberately leaves them alone so a custom file can replace them (upstream
[ClickStack#2351](https://github.com/ClickHouse/ClickStack/pull/2351)). That is how the
normalisation below reaches the authed pipelines. `logs/in` has no processors in the base, so a
list can be added to it. A replaced list must repeat the base processors it still wants, so
re-read `/etc/otelcol-contrib/config.yaml` on every ClickStack bump.

Verify the merged result inside the container:

```bash
docker exec clickstack cat /etc/otel/supervisor-data/effective.yaml | grep -A 6 "traces"
```

## Gateway normalisation

`clickstack/otel-custom.yaml` runs three `transform` processors (OTTL on the resource, so one
statement list serves traces, metrics and logs). `transform` is beta upstream for all three
signals; the schema processor is alpha and not used. The bundled collector (0.155) ships
`transform`, `resource`, `attributes` and `filter`; check with
`docker exec clickstack /otelcontribcol components` after a bump.

| Processor | On | Does |
|-|-|-|
| `transform/env` | every pipeline | `production`→`prod`, any other value besides `prod`/`dev`→`dev` on `deployment.environment` and `deployment.environment.name`; copies the old key into `.name` when `.name` is missing |
| `transform/internal` | `:4319` pipelines (`*/internal`) | container-ID-looking `host.name` (12–64 hex) → `container.id`; `host.name` = `${TELEMETRY_HOST_NAME:-vps}` (everything on the docker bridge runs on this VPS; the dev stack sets `mini`) |
| `transform/authed` | the base `traces`, `metrics`, `logs/in` pipelines | container-ID-looking `host.name` → `container.id`, `host.name` dropped; for `otelcol-hyperdx` and `clickhouse` (nothing else sets their resource) `host.name`, `service.namespace=vps`, `deployment.environment.name` are stamped |

`logs/in` runs before the routing connector, so session replay (`hyperdx_sessions`) is
normalised too. `session.id` handling of the base pipelines (`transform/session_id`) is kept in
the replaced `traces` list. What the gateway cannot reach: nothing on a pipeline today; what it
chooses not to touch is `service.namespace` and `service.version` of an app (the app's fix).

Both keys are kept (`deployment.environment` is rewritten, not removed) so queries on the old
key keep working. The dashboards and alerts in `observability/` filter on neither.

## How each component is wired

### Traefik (`compose.networking.yml` + `traefik/traefik.yml`)

```yaml
# traefik/traefik.yml — static config
tracing:
  otlp:
    http:
      endpoint: http://clickstack:4319    # unauthed internal port
  serviceName: traefik
  sampleRate: 0.1

metrics:
  otlp:
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
    http:
      endpoint: http://clickstack:4319
```

Traefik must be on `monitoring-net` (already wired). One trace per inbound
request hitting any router. Request-duration metrics per router/entrypoint/service
land in `default.otel_metrics_*` tables for HyperDX.

### Backend services (email-gateway as canonical example)

```yaml
# apps/email-gateway/compose.yml
environment:
  OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
  OTEL_SERVICE_NAME: email-gateway
  OTEL_RESOURCE_ATTRIBUTES: service.namespace=email-gateway,deployment.environment.name=prod
```

No `OTEL_EXPORTER_OTLP_HEADERS`. The SDK in the app (typically
`@opentelemetry/sdk-node`) appends `/v1/traces` and `/v1/logs` to the endpoint.

### Third-party containers (imgproxy as canonical example)

An off-the-shelf image may honour the standard `OTEL_*` vars for *where* to send
telemetry while keeping its own flag for *whether* to send any. imgproxy is
exactly this — v4 dropped `IMGPROXY_OPEN_TELEMETRY_{ENDPOINT,PROTOCOL}` in
favour of `OTEL_*`, but kept the enable flags:

```yaml
# apps/imgproxy/compose.yml
environment:
  IMGPROXY_OPEN_TELEMETRY_ENABLE: "true"          # without this, the rest is inert
  IMGPROXY_OPEN_TELEMETRY_ENABLE_METRICS: "true"
  IMGPROXY_OPEN_TELEMETRY_ENABLE_LOGS: "true"
  OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
  OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
  OTEL_SERVICE_NAME: imgproxy
  OTEL_RESOURCE_ATTRIBUTES: service.namespace=vps,deployment.environment.name=prod
```

Setting only the `OTEL_*` vars produces no error and no data — the service
starts happily and exports nothing. **Always confirm at the container's own
startup line rather than assuming**, then confirm rows actually land:

```
msg="OpenTelemetry monitoring" enabled=true logs=true metrics=true
```

### Browser-side SPAs

Browser SDKs cannot reach `:4319` (no public route). They go through Traefik's
public path to `:4318`:

```
Browser → <app>.${DOMAIN}/v1/traces → Traefik → clickstack-otel@docker → clickstack:4318
                                                                          (authed)
```

Routing labels on the app's frontend container (no SPA on this VPS uses them
today; Argo's dashboard, the former example, now runs on the mini and relays
browser OTLP to the authed tier itself):

```yaml
- "traefik.http.routers.<app>-otel-traces.rule=Host(`<app>.${DOMAIN}`) && Path(`/v1/traces`)"
- "traefik.http.routers.<app>-otel-traces.service=clickstack-otel@docker"
- "traefik.http.routers.<app>-otel-logs.rule=Host(`<app>.${DOMAIN}`) && Path(`/v1/logs`)"
- "traefik.http.routers.<app>-otel-logs.service=clickstack-otel@docker"
```

The browser SDK needs the ingestion key in its bundle (`VITE_HYPERDX_API_KEY`
for Vite, etc.). This is **public-by-design** — same pattern as Sentry DSN,
Datadog client token, PostHog public key.

The key lives at `op://vps/argo/HYPERDX_API_KEY_PROD` and is fanned out to every
GitHub repo via dotfiles' `make github-config` (single source of truth, rotation
= update 1P + re-run + redeploy consumers).

## Adding a new service that exports OTLP

### Backend container on monitoring-net

1. Add the service to `observability/services.yaml` (name, namespace, host, env, repo, signals).
2. Add it to `monitoring-net` in its compose service block.
3. Set the env vars (contract: [Telemetry contract](#telemetry-contract)):
   ```yaml
   OTEL_EXPORTER_OTLP_ENDPOINT: http://clickstack:4319
   OTEL_SERVICE_NAME: <product>-<role>
   OTEL_RESOURCE_ATTRIBUTES: service.namespace=<product>,deployment.environment.name=prod
   ```
4. Wire your app's OTel SDK to honor them (standard for `@opentelemetry/sdk-node`, Python, Go, etc.)
   and bake the short git SHA into `service.version` at build time.

No auth wiring, no secrets.

### Frontend SPA with browser ingest

1. Add the four Traefik routers + auth on the SPA's compose service:
   ```yaml
   - "traefik.http.routers.<app>-otel-traces.rule=Host(`<app>.${DOMAIN}`) && Path(`/v1/traces`)"
   - "traefik.http.routers.<app>-otel-traces.entrypoints=websecure"
   - "traefik.http.routers.<app>-otel-traces.tls.certresolver=letsencrypt"
   - "traefik.http.routers.<app>-otel-traces.priority=200"
   - "traefik.http.routers.<app>-otel-traces.service=clickstack-otel@docker"
   - (same four for /v1/logs)
   ```
2. In your build, pull the public ingestion key from `${{ secrets.HYPERDX_API_KEY_PROD }}`
   and pass to the bundler (e.g. `--build-arg VITE_HYPERDX_API_KEY=...`)
3. SDK init: point `url` at `window.location.origin` (same-origin, no CORS preflight)

### Cross-host (homelab → VPS)

Use the public path: `https://otel.${DOMAIN}/v1/traces` with `Authorization: <ingestion-key>`.
Same key, same threat model as browser ingest.

## Verification commands

```bash
# Recent spans by service
echo "SELECT ServiceName, count() AS spans FROM default.otel_traces \
      WHERE Timestamp > now() - INTERVAL 5 MINUTE GROUP BY ServiceName \
      ORDER BY spans DESC FORMAT PrettyCompact" \
  | docker exec -i clickstack clickhouse-client

# Receiver-level counters (acceptance vs refusal)
docker exec clickstack curl -s localhost:8888/metrics | \
  grep -E "otelcol_receiver_(accepted|refused|failed)_(spans|metric|log)"

# Normalisation check: nothing outside {prod, dev}, nothing but vps behind :4319
echo "SELECT ResourceAttributes['deployment.environment.name'] e, count() FROM default.otel_traces \
      WHERE Timestamp > now() - INTERVAL 1 HOUR GROUP BY e FORMAT PrettyCompact" \
  | docker exec -i clickstack clickhouse-client

# Live merged collector config
docker exec clickstack cat /etc/otel/supervisor-data/effective.yaml | less

# Probe the unauthed internal port from inside another monitoring-net container
docker exec <some-container-on-monitoring-net> sh -lc \
  'wget -qS --post-data="{}" --header="Content-Type:application/json" \
   http://clickstack:4319/v1/traces 2>&1 | head'
# Expected: HTTP/1.1 400 Bad Request (empty body is invalid protobuf — but auth OK)

# Probe the authed public port — same body, with auth header
docker exec <container> sh -lc \
  'wget -qS --post-data="{}" --header="Content-Type:application/json" \
   --header="authorization:<key>" http://clickstack:4318/v1/traces 2>&1 | head'
# Without the auth header you get 401.
```

## Key rotation

The HyperDX ingestion key (`op://vps/argo/HYPERDX_API_KEY_PROD`) is used by:
- Any frontend SPA whose build embeds it (currently: Argo's dashboard on the mini, built by `make deploy` in the argo repo)
- Any cross-host service that sends OTLP to the public ingress (currently: none on VPS)

To rotate:

```bash
op item edit "argo" "HYPERDX_API_KEY_PROD=<new-value>" --account tkrumm
cd ~/SourceRoot/argo && make deploy   # on the mini: rebuilds the dashboard with the new key
# Repeat the rebuild for any other frontend that embeds the key.
```

Internal services on `:4319` don't need rotation — they don't use the key.

## Agent access — MCP + REST

Agents (Claude Code sessions and the `otel` skill) reach ClickStack over two
HTTP surfaces, both proxied by the HyperDX UI container and both authenticated
with a HyperDX **user access key** — not the OTLP ingestion key above, a
different credential with a different threat model (see "Two credentials"
below).

### The two URLs

| Surface | URL | Shape |
|-|-|-|
| MCP (agent tools) | `<base>/api/mcp` | `POST`, stateless Streamable HTTP. Reply is SSE (`event: message` / `data: {json}`), even for a single request/response. |
| REST v2 | `<base>/api/api/v2/{dashboards,alerts,webhooks,savedSearches,sources,connections,team}` | Plain JSON. The doubled `/api` is correct — the UI's `/api/*` proxy forwards into the HyperDX API, which itself mounts the external router at `/api/v2`. |

`<base>` is `https://hyperdx.${DOMAIN}` in prod (Tailscale-only DNS — reachable
from the VPS host itself and from any tailnet machine) and
`http://localhost:7707` in dev (`compose.dev.yml` publishes `8080→7707`).

Both headers on every call: `Authorization: Bearer <access key>`,
`Content-Type: application/json`. MCP additionally needs
`Accept: application/json, text/event-stream`.

### Two credentials, not one

| Credential | Scope | Where it lives | Who holds it |
|-|-|-|-|
| OTLP ingestion key (`HYPERDX_API_KEY`, rotation above) | write-only — accepts telemetry | public, embedded in frontend bundles | any browser |
| HyperDX **user access key** | full read/write on everything the user can see — dashboards, alerts, saved searches, MCP tools | `users.accessKey` in Mongo | one human, or one dedicated agent user |

The user access key is the same credential the HyperDX UI itself uses once
you're logged in — it is not a scoped API token. Handing it to an agent means
handing that agent the same power a logged-in human has.

### Why a dedicated agent user

The human's own HyperDX login is a real password behind a real login form —
screenshots, session cookies, and manual dashboard edits all go through it. An
agent needs the access key on disk (mini-cached, headless-readable) to call
MCP/REST unattended. Rather than cache the human's password-derived key
there, `make hyperdx-agent-setup` provisions a **second** HyperDX user
(`op://vps/clickstack/AGENT_EMAIL`) whose access key is a value **we** choose
(`AGENT_ACCESS_KEY`) — so the human's own credential never needs to leave
their session, and the agent's key can be rotated or revoked independently by
deleting/re-inviting the agent user.

### 1Password fields (prod, `vps` vault, item `clickstack`)

Create these **by hand** first — the VPS service account has no write
permission to 1Password:

| Field | Value |
|-|-|
| `AGENT_EMAIL` | `<agent-email, e.g. hyperdx-agent@jkrumm.com>` |
| `AGENT_PASSWORD` | 12-72 chars, upper + lower + digit + special (HyperDX's password policy) |
| `AGENT_ACCESS_KEY` | a uuid v4, lowercase |

### Setup / bootstrap targets

| Target | Env | What it does |
|-|-|-|
| `make hyperdx-agent-setup` | prod | Idempotent. Invites (if missing) `AGENT_EMAIL` via the team-setup-token flow, then forces its `accessKey` to `AGENT_ACCESS_KEY`. Ends with an MCP `initialize` smoke test. |
| `make hyperdx-dev-bootstrap` | dev | Idempotent. Ensures `~/.config/hyperdx/local.env` exists (generates `dev@hyperdx.test` + a policy-compliant password if missing), registers the first Mongo user if none exists, refreshes `HYPERDX_LOCAL_ACCESS_KEY` from Mongo. Same MCP smoke test against `http://localhost:7707`. |

Neither script ever prints a secret value — `hyperdx-agent-setup.sh` prints
`user ok` / `accessKey ok`; the dev script prints the same plus a
"generated"/"registered" line only the first time it runs.

### Dashboards as code

`make hyperdx-export ENV=<dev|prod>` and `make hyperdx-apply ENV=<dev|prod>`
wrap `scripts/hyperdx-sync.sh` over the REST v2 dashboards endpoint. Dashboards
live at `observability/dashboards/*.json` — see `observability/README.md` for
the full loop. In short: `export` pulls every dashboard down (ids/timestamps
stripped so files are env-portable), `apply` validates
(`POST /dashboards/validate`) then upserts **by dashboard name** (`PUT` if a
same-named dashboard exists in the target env, else `POST`).

### Alerts → ntfy

`make hyperdx-webhook-setup` (prod-only, idempotent) creates or updates a
HyperDX webhook named `ntfy alerts` (service `generic`) that POSTs to
`https://ntfy.<DOMAIN>/alerts` with `Authorization: Bearer` from
`op://common/ntfy/TOKEN` and a body template (alert name, state, value vs
threshold, window, link; static `Title`/`Priority`/`Tags` headers — HyperDX does not template
headers, and `{{body}}` carries escaped `\n`). Headers are write-only in HyperDX, so
every run PUTs. Run it once before applying any alert that notifies over ntfy —
alerts reference this webhook by **name**, not id. Watchtower and RollHook post to
the topic `updates` with the same token (`NTFY_TOKEN` in `.env.tpl`).

### Alert channels

Every alert in this directory lists exactly one `channel` in `channels` (HyperDX >= 2.36 takes 1–10; the singular
`channel` is just `channels[0]`): `Factory door`, the factory's alert door, which files an Issue in the repo its route names
(`factory door route`, kept in the factory's database, matched on the quoted name in HyperDX's alert title) and forwards an unsolved one after 30 minutes. The `ntfy alerts` webhook still exists
(`make hyperdx-webhook-setup`) but no alert uses it; add it back to an alert's `channels` for a direct push. A generic `Warden ingest` webhook used to
sit next to it until warden was switched off (2026-10-27); it was deleted from HyperDX and
the alert files. weatherorb's four alerts are not in this directory: that repo
applies them with its own `WeatherOrb ops.alert` webhook, and `export` skips
the `weatherorb` tag. The `agw` dashboard and its alerts belong to agent-workflows
(`packages/hyperdx`, `make hyperdx-apply`); `export` skips the `agw` tag on dashboards
and alerts. `apply` always sends `channels` (+ the `channel` mirror):
a body with only `channel` would silently reduce an alert to one webhook.

### Per-app error alerts → factory Issues

Every app that sends telemetry has an error alert (or several) on the `Factory door` webhook, so an app's errors become an
Issue in its own repo. The door's `hyperdx` source (one token, held in the `Factory door` webhook's headers) takes every alert;
the **repo comes from a door route**, not from the alert: with an alert's `name` set, HyperDX uses it verbatim as the
notification title, the door's monitor is that name, and `factory door route-set --source hyperdx --monitor "<name>" --repo
<repo>` (owner-only, kept in the factory database) sends it to a repo. The threshold is part of the name, so a threshold
change is a new monitor and needs a new route — rename and re-route together.

Tiles live on `Apps — Errors` (`observability/dashboards/apps-errors.json`), except `fpp browser errors`, which reuses the
`Browser errors` tile of the Free Planning Poker dashboard. Each counts error spans (or error logs) over the alert window;
4xx are left out on purpose (imgproxy dead sources, bad signatures, scanners).

| Alert name (= door monitor) | Repo | Counts |
|-|-|-|
| `fpp server errors >= 3 (15m)` | free-planning-poker | fpp-server / fpp-analytics 5xx or error spans |
| `fpp browser errors >= 20 (1h)` | free-planning-poker | browser SDK error spans and `console.error` |
| `argo-api server errors >= 5 (15m)` | argo | argo-api HTTP 5xx |
| `argo-dashboard browser errors >= 20 (1h)` | argo | argo-dashboard error spans and `console.error` |
| `iris-server errors >= 10 (1h)` | iris | iris-server error spans |
| `iris app errors >= 3 (1h)` | iris | iris-ios / iris-macos error logs |
| `imgproxy 5xx >= 3 (15m)` | vps | imgproxy HTTP 5xx |
| `shutterflow imgproxy 5xx >= 3 (15m)` | shutterflow | shutterflow-imgproxy(-small) HTTP 5xx |
| `shutterflow-share server errors >= 3 (15m)` | shutterflow | shutterflow-share 5xx or error spans |
| `email-gateway errors >= 3 (15m)` | email-gateway | email-gateway error spans |
| `rollhook error logs >= 1 (15m)` | rollhook | rollhook error logs |

The older hand-written alerts (email-gateway ops, shutterflow ops, VPS edge/error logs, OTel ingest) keep their routes.
weatherorb's alerts live in its own repo. Not covered: `agw`, `agw-gateway`, `opencode` (tooling; their error spans carry no HTTP status and
sit at 5–6 % steady state) and `traefik` (the `VPS edge` alerts).

Alerts themselves are code too: the same `hyperdx-export`/`hyperdx-apply`
targets also cover `observability/alerts/*.json`, using the REST v2 `/alerts`
endpoint (source: `saved_search` or `tile`; threshold + thresholdType +
interval + a `channel: {type: "webhook", webhookId}`). Exported files swap
`dashboardId`/`tileId`/`savedSearchId`/`channel.webhookId` for
`dashboard`/`tile`/`savedSearch`/`channel.webhook` names, which `apply`
resolves back into the target env's ids — see `observability/README.md` for
the full loop and file shape.

Silence an alert either from the HyperDX UI (per-alert silence with an
expiry) or by writing a `silenced: {by, at, until}` block through the
`save_alert` MCP tool — REST v2's alert schema doesn't accept `silenced` on
write, so a silence set via MCP doesn't round-trip through
`hyperdx-export`/`hyperdx-apply` (by design: silences are operational state,
not desired configuration).

### Deep-linking to a dashboard

`https://hyperdx.${DOMAIN}/dashboards/<id>?from=<epoch-ms>&to=<epoch-ms>&kiosk=true`
— `kiosk=true` hides the HyperDX chrome (useful when embedding a screenshot or
sharing a fixed time window). `<id>` comes from a dashboard's REST v2 `id`
field (`GET /api/api/v2/dashboards`).

## Host agent

`host-agent` and `host-probe` (`compose.monitoring.yml`) put the VPS's host and container metrics into ClickStack. Both run the same
image, a slim OpenTelemetry Collector built from `agent/manifest.yaml` with ocb (`agent/README.md`: why it is built, how to bump it,
how another machine runs it). Everything lands in `otel_metrics_*` with `host.name=vps`, `service.namespace=infra` and
`deployment.environment.name=prod`. The same two containers run on the homelab (homelab Issue 2092, 2026-11-18: `host.name=homelab`, containers only, no `httpcheck.*` or `ping.*`, no temperature because the 0.165.0 hostmetrics receiver has no hardware scraper) and `host-agent` on the mini; both send OTLP/HTTP to the authed tier `https://otel.<domain>` with the ingestion key, so the registry lists `host-agent` and `host-probe` once, with every host that runs them.

| Container | Network | Collects | Sends to |
|-|-|-|-|
| `host-agent` (`service.name=host-agent`) | host namespace | `system.*`: CPU (`utilization` per state), memory, load, swap, disk I/O, filesystem utilisation per mount, network I/O per interface, process counts, uptime | `http://127.0.0.1:4319` |
| `host-probe` (`service.name=host-probe`) | bridge | `container.*` through `socket-proxy-monitoring` (CPU, memory, restarts, health), `httpcheck.*` for the public sites, `ping.*` (loss, RTT) to two public resolvers | `http://clickstack:4319` |

**Why two containers.** The network scraper reads `/proc/net/dev`, which shows the namespace of the reading process: in a bridge
container `system.network.io` would be the container's own eth0. So `host-agent` shares the host namespace, and cannot resolve
`clickstack`; `compose.monitoring.yml` publishes ClickStack's unauthenticated :4319 on `127.0.0.1` for it (never a routable
interface). Unprivileged ICMP needs the `ping_group_range` Docker sets in a bridge container (the host has `1 0`, which turns it
off in the host namespace), and `docker_stats` reaches the read-only proxy by name, so `host-probe` stays on the bridge. The raw
Docker socket is mounted nowhere. `host-agent` has no capability, a read-only root filesystem and the host filesystem mounted
read-only; it needs the mount for filesystem and disk statistics.

**Deliberately off:** the per-process scraper (one series per process), `system.cpu.time` (the utilisation gauge replaces it),
per-container network and block I/O (the host half has both), per-interface series of `veth*`, `br-*` and `docker*`.

**Queue.** The exporter queue is on a volume (`host-agent-queue`, `host-probe-queue`) and retries never give up, so samples
collected while ClickStack is down arrive after it returns with the timestamps they were collected with.

**Queue test (2026-11-17):** `docker stop clickstack` 19:41:03 → `docker start` 19:46:05 UTC. Afterwards `default.otel_metrics_gauge` held 40 `host-agent` rows in every minute of the gap (the same as before and after it) and 147–151 `host-probe` rows per minute (four fewer while the stopped `clickstack` container had no stats of its own): nothing was lost, and the rows carry the collection timestamps.

**Footprint** (measured 2026-11-17 on the VPS, one hour after start):

| | RSS after 1 h (peak, cgroup) | CPU over 1 h | Rows per day |
|-|-|-|-|
| `host-agent` | 27.6 MiB (24.1 MiB peak) | 10 s of CPU time, 0.27 % of one core | 57,600 gauge + 157,000 sum = 215,000 |
| `host-probe` | 34.9 MiB (34.0 MiB peak) | 19 s of CPU time, 0.51 % of one core | 221,000 gauge + 525,000 sum = 746,000 |

Both containers run with `mem_limit: 128m` (3.7 × the larger peak, which includes the catch-up after the five-minute ClickStack outage of the queue test) and a `memory_limiter` at 96 MiB; no OOM event. Together they add about 0.96 million rows a day to `otel_metrics_gauge` and `otel_metrics_sum` (the 25-minute window of 19:15 UTC, scaled), which at the measured 10 bytes per gauge row and 16 per sum row is about 13 MB a day and 0.4 GiB per 30 days, inside the metrics budget of the Retention table. `host-probe` is three quarters of it: `container.state.health.status` reports three states for each of the 22 containers with a healthcheck at every scrape (66 rows of 150). If the volume ever matters, that metric and `container.memory.usage.limit` are the first to drop.

### Infra alerts

All alerts are on `Infra — Hosts` (`observability/dashboards/infra-hosts.json`), go to the `Factory door` webhook, and are routed
to this repo (`factory door route-set --source hyperdx --monitor "<name>" --repo vps`). Disk, memory, load, swap and container
alerts group by `host.name` (and mount or container name), so a host that starts reporting is alerted on without an edit: the homelab's `/`, `/mnt/hdd`, `/boot`, `/boot/efi` and `/mnt/transfer` are on the filesystem alert and its memory on the memory alert from the first sample. The container tiles group by host and container name, since `cloudflared`, `dozzle`, `watchtower` and `beszel-agent` run on both machines. The homelab's containers report no `container.state.health.status` series (none has a healthcheck), so `Infra container unhealthy` has nothing to say about it until one does.
The threshold is part of the name; changing one is a new monitor and needs a new route.

| Alert | Fires when | Window |
|-|-|-|
| `Infra filesystem >= 85% (15m)` | any mount of any host except the mini is at least 85 % full | 3 × 5 m |
| `Infra mini filesystem >= 93% (15m)` | any mount of the mini (in practice `/System/Volumes/Data`) is at least 93 % full | 3 × 5 m |
| `Infra memory >= 90% (15m)` | `system.memory.utilization` state `used` (without cache) at least 90 % | 3 × 5 m |
| `Infra swap-out >= 100 MiB per 5m (15m)` | the swap pages written out (`system.paging.operations`, direction `page_out`, type `major`) in each of three consecutive 5 m windows | 3 × 5 m |
| `Infra container restarts >= 1 (15m)` | `container.restarts` increased | 15 m |
| `Infra container unhealthy >= 1 (10m)` | a container with a healthcheck reports `unhealthy` | 2 × 5 m |
| `<host> host silent < 1 sample (10m)` | no `system.cpu.utilization` sample of that host: `vps host silent`, `homelab host silent` (the mini has none yet) | 2 × 5 m |

Each alert was proved once on 2026-11-17: its threshold lowered until it fired, the Issue arrived at the door (`incident` on the route's Issue), the threshold restored and the state back to OK. The first firing at 19:05 UTC went nowhere: HyperDX 2.45 refuses a webhook whose host resolves to a private or CGNAT address, which the door's tailnet name does, so every alert since the 2.45 pin failed with `WEBHOOK_ERROR` in its `executionErrors`. `WEBHOOK_HOSTNAME_ALLOWLIST` on the clickstack service names the door host; if alerts stop arriving, read `executionErrors` first (`agw hdx rest /alerts/<id>`).

**Mini disk.** The mini's Data volume (926 GiB) sits at 88 to 92 % in normal operation: weatherorb's round builds, factory worktrees and the Colima VM disk (dotfiles `docs/disk.md`). The 85 % line fired on it at 89 % with 101 GiB free (Issue 2155) and would fire permanently: each sweep and worktree reap in `docs/disk.md` has bought 1 to 4 points that came back within hours. The mini therefore has its own tile and alert at 93 %, the line the mini's `devhost-health` monitor already fails on (above the 92 % a round build or a pair of Rust `target/` dirs reaches), and the generic filesystem tile leaves it out with `host.name != 'mini'`. Below 93 % the mini's disk is a trend to read on the `Filesystem utilisation: mini (%)` tile; its sweeps and what to cut when it crosses are `docs/disk.md` in dotfiles. Raising or lowering the line is a new monitor and needs a new door route.

**Load has no alert.** The VPS runs CI next to prod, and CI alone drives its load: on 2026-11-17 the load5 average was 27, 18, 23 and 24 on 12 cores in four consecutive hours (CPU idle 10 to 18 %), peak load5 per core 6, from the weatherorb runners' `pytest -n auto` and factory build steps, while the edge p50 stayed at 2 to 13 ms. The `load5 per core >= 4 (15m)` alert (filed at 1.5, raised to 4) fired through it with nothing wrong, so it is gone: load counts queued CI threads, not harm to prod. Prod is protected where it matters, by priority: every runner lives in `ghrunner.slice` with `CPUWeight=20` against `system.slice`'s 100 (`docs/gh-runner.md`), and the harm alerts stay (edge p95 and 5xx, memory, swap-out, container unhealthy, host silent). `Load5 per core` remains a tile on `Infra — Hosts` for reading.
Swap is judged by activity, not by how full it is: the VPS keeps cold pages in swap at 94 % use without trouble, and paging that
keeps going is what hurts.

A grouped alert cannot notice a host whose series vanished entirely, so **host silent is one alert per host**. To add one: in
`infra-hosts.json` copy the tile `host-agent samples: vps (10m silence alerts)` and change the host in its `where`; in
`observability/alerts` copy `vps-host-silent-1-sample-10m.json`, change the name (`<host> host silent < 1 sample (10m)`) and the
tile; add the host to `host-agent`'s `host` list in `observability/services.yaml`; `make hyperdx-apply ENV=prod`; `factory door route-set
--source hyperdx --monitor "<name>" --repo <repo>`; `make hyperdx-export ENV=prod` and commit. The homelab's is in; the mini's is still to add.

**Against Beszel** (retired once ClickStack covers it): status → host silent, memory → memory, swap → swap-out, swap growth →
swap-out, disk → filesystem. Beszel's load rule and its CPU 80 % for 10 minutes were digests, not alerts: they have tiles
(`Load5 per core`, `CPU utilisation`) but no alert here.

### Docker metrics for the container alerts

`docker_stats` exposes both: `container.restarts` (a counter per container, from the Docker restart count) and `container.state.health.status` (one series per health state for each container that has a healthcheck, `unhealthy` is the alert). Containers without a healthcheck cannot be unhealthy here; a container that exited disappears from the list, which the `Running containers` tile shows and no alert covers.

### Verify

```bash
agw hdx query clickstack_query_tiles '{"dashboardId":"<Infra — Hosts id>","startTime":"<iso>","endTime":"<iso>"}'   # every tile returns rows
ssh vps 'docker logs --tail 20 host-agent; docker stats --no-stream host-agent host-probe'
```

## CI telemetry

GitHub Actions runs and jobs of every repo of the owner (hosted and self-hosted) land in ClickStack as `ci-poller` (namespace `ci`, host
`mini`). The dashboard is **CI — GitHub Actions** (`observability/dashboards/ci-github-actions.json`): runs, failures, run and job
duration, queue time and the VPS runners' busy share, per repo and per runner. A run appears one poll tick (60 s) after GitHub marks it
completed; the runs waiting and the runner load are sampled every tick.

**Why a poller.** The options were the contrib `githubreceiver` and a webhook into OTLP, or polling the REST API (researched 2026-11-17):

| Option | Verdict |
|-|-|
| `githubreceiver` webhook mode (runs and jobs to traces) | Alpha, and GitHub must POST to a public URL: a new public endpoint (HMAC only), plus one webhook per repo, because a personal account has no account-level hooks. Rejected |
| `githubreceiver` scraper mode | Repository, branch and pull-request metrics; no workflow runs, jobs or runner data. Not a CI source |
| In-workflow OTLP actions | A public OTLP endpoint and an edit in every workflow of every repo. Rejected |
| **Polling the REST API** | Outbound only, one token, no per-repo setup: a new repo shows up on its own. Chosen |

**How it runs.** `scripts/gh-actions-telemetry.py` (Python stdlib; tests in `scripts/test_gh_actions_telemetry.py`, part of `make check`) is one
poll tick. The LaunchAgent `com.jkrumm.vps-gh-actions-telemetry` (`launchd/`, registered in `mini-services.yaml`) runs it every minute through
`jobrun`, so a failed tick or a stopped schedule is graded and reaches Slack `#alerts`. It runs on the mini, not here, for one reason: the
GitHub credential (`op://mini/github/token`) is already in the mini's offline secret cache; the VPS holds no GitHub token and a new one is a portal
step. It sends OTLP/JSON to `https://otel.<domain>` (the authed tier) with the ingestion key. Secrets: `launchd/gh-actions-telemetry.env.tpl` (1Password refs,
read by `secrets-run`); nothing else is configured.

```bash
make gh-actions-launchd             # on the mini, from the MAIN checkout: install / reload the LaunchAgent
make gh-actions-telemetry-run       # one tick by hand, prints its counters
tail ~/Library/Logs/vps-gh-actions-telemetry.log
```

**What it reads.** Per tick: the owner's repos (cached 1 h), then each repo's `GET /actions/runs` with an ETag. An unchanged repo answers 304,
which GitHub does not count against the 5,000 requests per hour; a repo without runs is looked at again after 10 min. A completed run costs one
`/jobs` call, an in-progress run one per tick. The first tick backfills the last 24 h (50 runs per tick, so about ten ticks); the state file
(`~/.local/state/gh-actions-telemetry/state.json`) keeps which runs went out, and the span ids are derived from run and job ids. Delete the
state file to re-send 24 h (it duplicates rows: do not).

| Signal | Name | Attributes |
|-|-|-|
| Trace | one `run` span per workflow run (name: the workflow), a `job` span (started to completed) and a `queue` span (created to started) per job, same trace | `ci.kind` (`run`/`job`/`queue`), `vcs.repository.name`, `cicd.pipeline.name`, `cicd.pipeline.result`, `cicd.pipeline.task.name`, `cicd.pipeline.task.run.result`, `cicd.worker.name`, `ci.runner` (the runner's name, or `github-hosted`), `ci.runner.kind` (`self-hosted`/`hosted`), `vcs.ref.head.name`, run and job URLs. A failed run or job is an Error span |
| Gauge | `ci.worker.busy` | `ci.runner.name`, `vcs.repository.name`: 1 while a job of an in-progress run sits on that self-hosted runner, else 0. The busy share is its average |
| Gauge | `ci.pipeline.run.active` | `vcs.repository.name`, `cicd.pipeline.run.state` (`pending` = waiting for a runner, `executing`); one trailing 0 when a repo goes quiet |
| Gauge | `ci.poll.repos` | the number of repos polled: the poller's heartbeat |

Names follow the OpenTelemetry CI/CD and VCS conventions (`cicd.*`, `vcs.*`); the rest is `ci.*`. GitHub timestamps have one-second resolution, so a queue
time under a second reads 0 and a 1 s job rounds to 0 or 1.

**Limits.** GitHub does not list a self-hosted runner that has never run a job in the 24 h window, so it has no busy series until it does; the Admin
API for runners is not used because the token has no administration scope. A run that is re-run keeps one run id: the earlier attempt is emitted only
if a tick saw it complete before the re-run. Steps are not emitted (about 13 per job; the job span covers them). The credential is the mini's push token,
used for GET only; a fine-grained token with Actions and Metadata read on all repos replaces the ref in `gh-actions-telemetry.env.tpl` without a code change.

**Verify.**

```bash
ssh vps 'docker exec clickstack clickhouse-client --query "SELECT SpanAttributes['"'"'ci.kind'"'"'] k, count() n, max(Timestamp) newest FROM default.otel_traces WHERE ServiceName='"'"'ci-poller'"'"' GROUP BY k"'
agw hdx query clickstack_query_tiles '{"dashboardId":"<CI — GitHub Actions id>","startTime":"<iso>","endTime":"<iso>"}'   # every tile returns rows
```

## Retention

Four tiers; ClickStack's default is 30 days for everything.

| Tables | TTL | Why |
|-|-|-|
| `otel_logs`, `otel_traces` (and their `*_rollup_*` tables) | 30 days | debugging window |
| `hyperdx_sessions` | 14 days | session replay is the largest table (2.6 of 6.1 GiB on 2026-11-17) and is only useful while a bug is fresh |
| `otel_metrics_gauge/sum/histogram/summary/exponential_histogram` | 400 days | host and line-quality history must outlive 30 days; all metrics tables together stay under 2 GiB per 30 days (measured 2026-11-17; traefik is ~75 % of the rows) |

Two places have to agree. `compose.monitoring.yml` sets `HYPERDX_OTEL_EXPORTER_{LOGS,TRACES,SESSIONS,METRICS}_TTL`
(`30d`, `30d`, `14d`, `400d`), which ClickStack's schema migration applies **when it creates a
table**; existing tables keep their TTL. So a change is two steps: edit the compose env, then
alter the live tables (`HYPERDX_OTEL_EXPORTER_RECONCILE_TABLE_TTL=true` would do the second
step on every start, but it also lets a later, shorter value delete data without a review, so it
stays off):

```bash
docker exec clickstack clickhouse-client --multiquery --query "
  ALTER TABLE default.hyperdx_sessions MODIFY TTL TimestampTime + toIntervalDay(14);
  ALTER TABLE default.otel_metrics_gauge MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(400);
  ALTER TABLE default.otel_metrics_sum MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(400);
  ALTER TABLE default.otel_metrics_histogram MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(400);
  ALTER TABLE default.otel_metrics_summary MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(400);
  ALTER TABLE default.otel_metrics_exponential_histogram MODIFY TTL toDateTime(TimeUnix) + toIntervalDay(400)"
```

`MODIFY TTL` rewrites the existing parts (TTL materialisation), so run it off-peak. Check:
`SELECT name, engine_full FROM system.tables WHERE database = 'default'` and read the `TTL` clause. The tables
use `ttl_only_drop_parts = 1`: a part goes when its newest row expires.

## System log TTL — ClickHouse's own logs, not OTel data

`clickstack/system-log-ttl.xml` (mounted to
`/etc/clickhouse-server/config.d/`) caps `trace_log`, `part_log`, `query_log`,
`metric_log`, `asynchronous_metric_log` and `processors_profile_log` at 7
days (`<ttl>event_date + INTERVAL 7 DAY DELETE</ttl>`). These are ClickHouse's
internal diagnostic logs and ship with no TTL at all — unrelated to the OTel
data (`otel_*`/`hyperdx_*` tables), whose retention is tiered (next section).

**Why it regrows without this**: applying (or changing) a system-log table's
config renames the existing table aside to a numbered `<table>_N` copy and
creates a fresh one on ClickHouse restart. The `clickstack` image is
pinned and excluded from Watchtower, so only a manual version bump orphans another `_N`
copy with no TTL of its own — these accumulate forever until dropped by
hand. First cleanup (2026-09-08) reclaimed ~47 GB this way.

ClickStack is pinned at `2.45.0` (bundled ClickHouse 26.10; 2.43.1 shipped 26.8).
The 2.45.0 bump (2026-11-17) renamed every TTL'd log table aside (`trace_log_5`,
`part_log_1`, `metric_log_4`, …; `metric_log` switched to the bucketed schema) and the
renamed copies kept the old 7-day TTL. `query_views_log` and `opentelemetry_span_log`
are not in `system-log-ttl.xml`, so their `_N` copies had none. All `_N` tables were
dropped after the upgrade. Each bump is followed by the check below.

Check for orphans and confirm the live table is the one being written:

```bash
docker exec clickstack clickhouse-client --query "
  SELECT table, formatReadableSize(sum(bytes_on_disk)) size, max(modification_time) newest
  FROM system.parts WHERE active AND database = 'system' AND table LIKE '%\_%'
  GROUP BY table ORDER BY sum(bytes_on_disk) DESC FORMAT PrettyCompact"
```

A stale `newest` (weeks/months old) confirms an orphan — drop it with
`DROP TABLE system.<table> SYNC`. Never drop the un-suffixed table itself.

## Dashboard read access — ClickHouse over the tailnet

Argo (on the Mac mini) renders its dashboards from ClickHouse directly, not from HyperDX.

| | |
|-|-|
| Endpoint | `http://<VPS_TAILSCALE_IP>:8123` (ClickHouse HTTP, no TLS; WireGuard encrypts the tailnet hop) |
| User | `argo_ro` |
| Password | `op://vps/clickstack/ARGO_RO_PASSWORD` (what the Argo side requests) |
| Hash ClickHouse checks | `op://vps/clickstack/ARGO_RO_PASSWORD_SHA256` (`.env.tpl` → `ARGO_RO_PASSWORD_SHA256` → `from_env` in `clickstack/argo-ro-user.xml`) |
| Scope | `SELECT` on `default.*` (`otel_*`, `hyperdx_*`); `system.*` is not granted |
| Limits | `readonly=1`, `max_execution_time` 15 s, `max_result_rows` 1,000,000, `max_memory_usage` 1 GB; all `throw`, so a query over a limit is cancelled |
| Source | `100.64.0.0/10` (the tailnet) |

Example (metrics are the 400-day table; always filter on `TimeUnix`, the sort key):

```bash
curl -sS --user "argo_ro:$ARGO_RO_PASSWORD" "http://<VPS_TAILSCALE_IP>:8123/" --data-binary "
  SELECT toStartOfHour(TimeUnix) AS t, MetricName, avg(Value) AS v
  FROM default.otel_metrics_gauge
  WHERE TimeUnix >= now() - INTERVAL 24 HOUR
  GROUP BY t, MetricName ORDER BY t FORMAT JSONEachRow"
```

**Reachability.** The tailnet ACL (`dotfiles-private/tailscale-acl.jsonc`) must grant the mini (`tag:devhost`) `tcp:8123` on `tag:vps`; without the grant the connection times out while ping works, as it does for any port not granted.

**Why the bind address matters.** Docker publishes ports through its own iptables rules, which bypass ufw: a
bare `8123:8123` would be open on the public address regardless of ufw's default-deny. The compose binding is
`${VPS_TAILSCALE_IP}:8123:8123`, the same as the 13133 health port, and 8123 is never routed through Traefik or the
Cloudflare tunnel. `lint-compose.py` rejects a port without that bind.

**Client notes.** `readonly=1` forbids changing any setting, so a client must not send settings (`SET`, or
URL parameters such as `max_execution_time`, `wait_end_of_query`): they fail with "Cannot modify ... in readonly mode".
The limits above are the user's profile and apply as-is.

**Other ClickHouse users.** The image ships `api` (password `api`) and `worker` (password `worker`) with full rights
and `::/0` as source. Nothing uses them (the query log shows `default` only), so `clickstack/argo-ro-user.xml` narrows both to loopback:
without that, publishing 8123 would expose them to every tailnet device. `default` (HyperDX's user) is untouched and
loopback-only already.

### Rotation / first setup

The VPS service account cannot write to 1Password, so both fields are written together from a machine with a
signed-in `op` (a different password and its hash must never be set apart):

```bash
p=$(openssl rand -base64 32 | tr -d '/+=\n')
h=$(printf %s "$p" | shasum -a 256 | cut -d' ' -f1)
op item edit clickstack --vault vps --account tkrumm "ARGO_RO_PASSWORD[password]=$p" "ARGO_RO_PASSWORD_SHA256[password]=$h"
```

Then `make clickstack-recreate` on the VPS (the config is bind-mounted, a plain `up -d` keeps the old one) and refresh the
Argo side's cached secret. Create the fields before pulling an `.env.tpl` that references them: one unresolvable
reference breaks every make target.

## Deploy regression to know about

**The `make <app>-up` targets pin the running image.** `${IMAGE_TAG:-...:latest}`
falls back to `:latest`, and RollHook never updates `:latest` (it tags by git SHA
only). A naive `up -d` would roll the running containers back to whatever was at
`:latest` when the registry was first seeded. So each RollHook app's `-up` target
reads the *currently running* image SHA out of docker and pins it, which makes
recreate-with-config-change work without pulling.

To deploy new code, always go through RollHook: push to the app's master (or use
the dev-only `make <app>-redeploy` where one exists). RollHook builds the
SHA-tagged image, pushes, and rolling-restarts the containers.

## References

- [Traefik OTLP tracing config (3.x)](https://doc.traefik.io/traefik/observability/tracing/opentelemetry/)
- [Traefik OTLP metrics config (3.x)](https://doc.traefik.io/traefik/observability/metrics/opentelemetry/)
- [Traefik helm-chart #1361 — env-var header bug](https://github.com/traefik/traefik-helm-chart/issues/1361)
- [Traefik #11992 — v3.5 OTLP regression](https://github.com/traefik/traefik/issues/11992)
- [ClickStack collector customization](https://clickhouse.com/docs/use-cases/observability/clickstack/ingesting-data/otel-collector)
- [OTel collector otlpreceiver — multi-instance + auth](https://github.com/open-telemetry/opentelemetry-collector/blob/main/receiver/otlpreceiver/README.md)
