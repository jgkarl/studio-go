# Multi-stage build. Debian-based (not Ubuntu) specifically so libvips-dev installs from the
# plain apt archive with no Ubuntu-Pro/ESM package gating to worry about.
FROM golang:1.25-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends libvips-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Installed as its own binary (not `go run` against our go.mod) so the CLI's own, much larger
# dependency tree doesn't need to be vendored into this project's go.sum.
RUN go install github.com/a-h/templ/cmd/templ@v0.3.1020

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN templ generate
RUN CGO_ENABLED=1 go build -ldflags="-s -w" -o /out/server ./cmd/server

FROM debian:bookworm-slim

# Runtime only needs the shared library, not -dev headers — same package the VPS deploy docs
# (docs/deploy.md) tell you to `apt install` directly for the no-Docker binary deploy path.
RUN apt-get update && apt-get install -y --no-install-recommends libvips42 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for least-privilege production operation.
RUN useradd -m -u 10001 appuser

WORKDIR /app
COPY --from=builder /out/server ./server
COPY --from=builder /src/db/migrations ./db/migrations
COPY --from=builder /src/static ./static

# Data directory for SQLite DB and media storage; owned by appuser.
RUN mkdir -p /data && chown -R appuser:appuser /data /app

USER appuser

ENV PORT=3000
ENV DB_PATH=/data/studio.db
ENV MEDIA_STORAGE_DIR=/data/media-storage
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fs "http://localhost:${PORT:-3000}/healthz" || exit 1

CMD ["./server"]
