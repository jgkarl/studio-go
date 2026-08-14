# ops/deploy.md — Production Deployment Guide (Docker Compose + Caddy)

> This guide covers the **containerised deployment path** using Docker Compose and Caddy on a
> single VM.  The non-Docker (git-clone + prebuilt binary + systemd) path is still in
> [docs/deploy.md](../docs/deploy.md) if you prefer it.

---

## Prerequisites

- A **Debian 12** VM (see sizing below) with Docker ≥ 24 and Docker Compose v2 installed.
- A domain whose `A` record points to the VM's public IP.
- Ports **80** and **443** open in the firewall/security group.
- `git`, `curl`, `sqlite3` on the host.

Install Docker on Debian 12:
```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # re-login after this
```

---

## VM sizing

### Hetzner (recommended for cost-sensitive single-tenant)

| Use case | Instance | vCPU | RAM | Disk | Est. cost |
|----------|----------|------|-----|------|-----------|
| Staging / low traffic | CX22 | 2 | 4 GB | 40 GB | ~€4–5/mo |
| Production baseline | CX32 | 4 | 8 GB | 80 GB | ~€11–14/mo |
| Image-heavy (libvips) | CX42 | 8 | 16 GB | 160 GB | ~€24–30/mo |

Additional costs: Hetzner Snapshots ~€0.01/GB/mo; Object Storage (Hetzner S3-compatible) starts
at ~€5/mo for 1 TB; Floating IP ~€0.50/mo. **Total typical starter bill: ≈ €15–20/mo.**

### AWS (if you need AWS ecosystem or enterprise integrations)

| Use case | Instance | vCPU | RAM | Est. compute (on-demand) |
|----------|----------|------|-----|--------------------------|
| Staging | t4g.small | 2 | 2 GB | ~$12/mo |
| Production baseline | t4g.medium | 2 | 4 GB | ~$24/mo |
| Image-heavy | t4g.large | 2 | 8 GB | ~$47/mo |

Add EBS gp3 storage: ~$0.08/GB-month (e.g. 80 GB ≈ $6.40).  
Add S3 for backups: $0.023/GB-month for storage + minimal request costs.  
Add IPv4: ~$0.005/hr (~$3.60/mo) per Elastic IP (AWS now charges for unused IPv4 too).  

**Total typical AWS starter bill: ≈ $30–60/mo.**

### Choose Hetzner when
Cost is a priority, you're in one region, and you don't need other AWS services.

### Choose AWS when
You already use RDS, SQS, CloudFront, or need enterprise IAM/compliance integrations.

---

## When to move from SQLite to Postgres

SQLite is excellent for this app while:
- Traffic is low-to-medium (< ~100 concurrent users).
- There is a single app instance (one writer).
- You can tolerate a brief write queue during heavy image processing bursts.

Consider migrating when:
- You need horizontal scaling (multiple app replicas).
- WAL mode write latency becomes measurable under load.
- You require advanced analytics queries or JSONB operators.
- You want managed HA failover (e.g., RDS Multi-AZ or PlanetScale).

The app's `internal/db` package uses a standard `database/sql` interface, so migrating drivers is
achievable with query adjustments for Postgres syntax.

---

## Environment variables

Copy `.env.example` to `.env` and fill in the required values:

```bash
cp .env.example .env
$EDITOR .env
```

**Required before first deploy:**

| Variable | Description |
|----------|-------------|
| `AUTH_SECRET` | 32+ byte hex secret — `openssl rand -hex 32` |
| `APP_URL` | Full `https://yourdomain.com` origin (used in emails) |
| `ALLOW_DEV_LOGIN` | Set to `false` in production |

**Optional (SMTP — leaves emails as journal logs if unset):**

| Variable | Description |
|----------|-------------|
| `SMTP_HOST` | Outbound mail relay hostname |
| `SMTP_PORT` | Default `587` |
| `SMTP_USER` | SMTP login |
| `SMTP_PASS` | SMTP password |
| `SMTP_FROM` | Sender address |

**Bootstrap first admin (one-time, remove after first boot):**

| Variable | Description |
|----------|-------------|
| `BOOTSTRAP_ADMIN_NAME` | Full name of first admin |
| `BOOTSTRAP_ADMIN_EMAIL` | Email of first admin |

> **Never commit `.env` to the repository.** It is listed in `.gitignore`.

---

## First deploy

1. **Clone the repo on the VM:**
   ```bash
   sudo mkdir -p /opt/studio && sudo chown $USER /opt/studio
   git clone https://github.com/jgkarl/studio-go /opt/studio
   cd /opt/studio
   ```

2. **Set up `.env`:**
   ```bash
   cp .env.example .env
   nano .env   # set AUTH_SECRET, APP_URL, ALLOW_DEV_LOGIN=false
   ```

3. **Configure Caddy** — edit `ops/Caddyfile` and replace `yourdomain.com` with your domain:
   ```bash
   nano ops/Caddyfile
   ```

4. **Build and start:**
   ```bash
   docker compose up -d --build
   docker compose ps        # verify all services are running
   docker compose logs -f   # watch logs
   ```

5. **Verify:**
   - `curl -fs https://yourdomain.com/healthz` should return `200 OK`.
   - Caddy auto-provisions a Let's Encrypt TLS certificate on first request.

---

## Updating (rolling deploy)

```bash
cd /opt/studio
git pull
docker compose up -d --build   # rebuilds image, replaces app container, keeps data volume intact
docker compose ps
```

> SQLite data persists in the `sqlite_data` named volume — it is never touched by `docker compose
> up --build` unless you explicitly remove it.

---

## Rollback basics

If a deploy is broken, roll back to the previous Git tag or commit:

```bash
git log --oneline -10                   # find last good commit
git checkout <commit-or-tag>            # check out that version
docker compose up -d --build            # rebuild and restart from that version
```

Or restore from a DB snapshot if schema migration is the problem (see Backup/Restore below).

---

## Backup / Restore

### Automatic scheduled backup (host cron)

Install `sqlite3` on the host:
```bash
sudo apt-get install -y sqlite3
```

Add a cron job (runs at 03:00 UTC daily):
```bash
crontab -e
```
```
0 3 * * * DB_PATH=/var/lib/docker/volumes/studio-go_sqlite_data/_data/studio.db \
           BACKUP_DIR=/opt/studio-backups \
           /opt/studio/ops/backup-sqlite.sh >> /var/log/studio-backup.log 2>&1
```

To also ship to S3-compatible storage, add `S3_BUCKET=s3://your-bucket/studio/sqlite` and ensure
the `aws` CLI is installed and configured (or use `rclone` with any compatible config).

**Recommended schedule:**
- Production: hourly (acceptable data loss: 1 hour)
- Staging: daily
- Adjust `KEEP_DAYS` env var to control local retention (default: 7 days)

### Manual snapshot

```bash
DB_PATH=/var/lib/docker/volumes/studio-go_sqlite_data/_data/studio.db \
BACKUP_DIR=/tmp \
./ops/backup-sqlite.sh
```

### Restore

```bash
# Stop the app first
docker compose stop app

# Restore from snapshot
SNAPSHOT=/path/to/studio-20260101-030000.db \
DB_PATH=/var/lib/docker/volumes/studio-go_sqlite_data/_data/studio.db \
./ops/restore-sqlite.sh

# Start the app
docker compose start app
docker compose logs -f app
```

The script saves the current DB as `studio.db.pre-restore-<timestamp>` before overwriting, so you
can always roll back the restore itself.

---

## Security notes

- The app runs as a non-root user (`uid=10001`) inside the container.
- SQLite data is on a named Docker volume (not exposed to the host FS by default).
- Secrets live only in `.env` (not committed — see `.gitignore`).
- Caddy enforces HTTPS and handles certificate rotation automatically.
- To restrict admin access by IP, add an `@allowed` matcher to `ops/Caddyfile`.

---

## Healthcheck

The app exposes `GET /healthz` which returns `200 OK` when the server is ready. Docker and Caddy
both use this endpoint to determine service health. Check manually:

```bash
curl -fs http://localhost:3000/healthz && echo "OK"
```
