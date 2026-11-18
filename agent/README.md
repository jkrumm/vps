# host-agent

A slim OpenTelemetry Collector for host monitoring, built with [ocb](https://opentelemetry.io/docs/collector/custom-collector/)
from `manifest.yaml`. One manifest, three platforms (linux/amd64, linux/arm64, darwin/arm64); the same agent goes onto every
machine. This directory is self-contained (no paths into the rest of the repo) so it can move to its own repository.

| | Contrib distribution | Core distribution | This build |
|-|-|-|-|
| Binary | 359 MB | 171 MB | 45 MB |
| Idle RSS, host metrics at 30 s | 180 MB | 79 MB | 40 MB |

Measured 2026-11-17 on the Mac mini with collector 0.165.0. Footprint on the VPS: `docs/observability.md` → Host agent.

## Layout

| File | What |
|-|-|
| `manifest.yaml` | The components (receivers, processors, exporters, extension), every module pinned to one release |
| `Dockerfile` | Multi-stage: ocb build (golang:alpine, pinned by digest) → distroless static, non-root |
| `build.sh` | Native binaries for the three platforms into `dist/` (ignored by git) |
| `patch-exporter.sh` | Writes the build manifest with a patched copy of the pinned `otlphttpexporter` (see below); `build.sh` and the `Dockerfile` both run it |
| `config/host.yaml` | Host metrics for a Linux host, per-host values from the environment |
| `config/vps-probe.yaml` | VPS only: container metrics, HTTP checks, ICMP |

`manifest.yaml` also carries `filelogreceiver` and the OTLP receiver for the machines that follow (log collection, a
gateway role); no config here uses them.

## Two configs, two containers on the VPS

| Container | Network | Why |
|-|-|-|
| `host-agent` | host namespace | The network scraper reads `/proc/net/dev`, which shows the namespace of the reading process: in a bridge container it would report the container's own eth0 as the host's |
| `host-probe` | bridge (`monitoring-net`, `socket-proxy-monitoring-net`) | `docker_stats` reaches the read-only socket proxy by name, and unprivileged ICMP needs the `ping_group_range` Docker sets in a bridge container (the host sets it to `1 0`, which disables ICMP in the host namespace) |

Both export OTLP/HTTP to ClickStack's unauthenticated tier. The exporter queue is on disk (`file_storage`), retries never
give up: stop ClickStack for five minutes and the samples collected meanwhile arrive afterwards with their original timestamps.

## Patched exporter

The stock `otlphttpexporter` (0.165.0) retries only 429, 502, 503 and 504; every other status is a permanent error and the
batch is dropped despite `retry_on_failure` and the disk queue. Cloudflare answers **530** while an origin is unreachable, so an
agent exporting through a Cloudflare route lost its samples for the whole outage. `patch-exporter.sh` copies the pinned module,
makes `isRetryableStatusCode` also accept 500-599 except 501 (not implemented, never transient), and appends a `replaces:` entry
to the manifest it hands ocb. It fails the build when the function is not found, so a version bump that moves it is loud.
Checked 2026-11-18: a 0.165.0 build against a server answering 530 logs "Will retry" and keeps the batch; it is dropped only on shutdown.
Drop the patch when upstream retries 5xx (watch the otlphttpexporter changelog on each bump).

## Update the collector

1. Change the version in `manifest.yaml` (every module), `OCB_VERSION` in the `Dockerfile` and `build.sh`, and the image tag in the compose file.
2. `agent/build.sh darwin/arm64` (or the platform at hand) and `host-agent validate --config <file>` for each config.
3. Deploy: `make deploy` builds the image on the VPS.

## Another host

Copy `config/host.yaml`, set `AGENT_HOST_NAME`, `AGENT_ENVIRONMENT` and `AGENT_OTLP_ENDPOINT` (the authed tier needs an
`Authorization` header on the exporter), mount the host filesystem read-only at `AGENT_ROOT_PATH`, then register
`host-agent` for that host in the telemetry registry and add its silent-host alert (`docs/observability.md`).
