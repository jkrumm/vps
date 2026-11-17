# syntax=docker/dockerfile:1
# host-agent: a slim OpenTelemetry Collector built from manifest.yaml with ocb. Build context is this directory.
# Base images are pinned by digest and bumped by hand together with the versions in manifest.yaml.
FROM golang:1.27-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
ARG OCB_VERSION=0.165.0
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0
WORKDIR /src
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    GOBIN=/usr/local/bin go install go.opentelemetry.io/collector/cmd/builder@v${OCB_VERSION}
COPY manifest.yaml .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} builder --config manifest.yaml
# The persistent exporter queue lives here; a named volume mounted on it inherits this ownership.
RUN mkdir -p /state

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931
COPY --from=build /src/_build/host-agent /host-agent
COPY --from=build --chown=65532:65532 /state /var/lib/host-agent
USER 65532:65532
ENTRYPOINT ["/host-agent"]
CMD ["--config=/etc/host-agent/config.yaml"]
