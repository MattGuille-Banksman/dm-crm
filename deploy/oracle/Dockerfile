# DM-CRM image: Corteza server built from this repository, plus the official
# web apps and the DM-CRM provisioning and branding.
#
# The official cortezaproject/corteza image is amd64 only; this one builds
# for whatever platform it is built on (arm64 on Oracle's free Ampere VMs).
# Build from the repository root:
#   docker build -f deploy/oracle/Dockerfile -t dm-crm:latest .

ARG VERSION=2026.9.0
ARG SASS_VERSION=1.69.5

# --- server ------------------------------------------------------------------
FROM golang:1.25-bookworm AS server
ARG VERSION
WORKDIR /src
COPY server/ ./
# embed the interface languages (what `make -C pkg/locale` does)
COPY locale/en ./pkg/locale/src/en
# sqlite needs cgo; dependencies are vendored, so no network is needed
RUN CGO_ENABLED=1 go build -mod=vendor \
      -ldflags "-X github.com/cortezaproject/corteza/server/pkg/version.Version=${VERSION}" \
      -o /out/corteza-server ./cmd/corteza

# --- web apps and sass ---------------------------------------------------------
FROM debian:bookworm-slim AS assets
ARG VERSION
ARG SASS_VERSION
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN mkdir -p /out/webapp \
 && curl -fsSL "https://releases.cortezaproject.org/files/corteza-webapp-${VERSION}.tar.gz" | tar -xz -C /out/webapp
RUN case "${TARGETARCH:-amd64}" in arm64) SASS_ARCH=arm64 ;; *) SASS_ARCH=x64 ;; esac \
 && curl -fsSL "https://github.com/sass/dart-sass/releases/download/${SASS_VERSION}/dart-sass-${SASS_VERSION}-linux-${SASS_ARCH}.tar.gz" | tar -xz -C /out

# --- runtime -------------------------------------------------------------------
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tzdata && rm -rf /var/lib/apt/lists/*

ENV STORAGE_PATH="/data" \
    HTTP_ADDR="0.0.0.0:80" \
    HTTP_WEBAPP_ENABLED="true" \
    HTTP_WEBAPP_BASE_DIR="/corteza/webapp" \
    HTTP_SERVER_ASSETS_PATH="/corteza/branding-assets" \
    PATH="/opt/dart-sass:/corteza/bin:${PATH}"

WORKDIR /corteza
COPY --from=server /out/corteza-server ./bin/corteza-server
COPY --from=assets /out/webapp ./webapp
COPY --from=assets /out/dart-sass /opt/dart-sass

# provisioning (base config plus the DM-CRM package) and branding
COPY server/provision ./provision
COPY branding/server-assets ./branding-assets
COPY branding ./webapp/branding

VOLUME /data
HEALTHCHECK --interval=30s --start-period=1m --timeout=30s --retries=3 \
    CMD curl --silent --fail --fail-early http://127.0.0.1:80/healthcheck || exit 1
EXPOSE 80
ENTRYPOINT ["./bin/corteza-server"]
CMD ["serve-api"]
