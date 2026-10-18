# Deploying Aasaan

One small server, Docker Compose, Caddy for automatic HTTPS, the SQLite file on a volume, a nightly backup.
No Kubernetes, no serverless, no App Runner (closed to new AWS customers).

> **Azure Container Apps**: For deploying to Microsoft Azure Container Apps (ACA) using the serverless container and Azure Files architecture, see the dedicated [DEPLOY-AZURE.md](DEPLOY-AZURE.md) runbook.

**SQLite means exactly one app instance.** Do not scale the `app` service. One 1 vCPU / 1-2 GB server is enough.

Status: the Compose file is validated and the app is tested locally. The Docker image build itself has **not** been run on
the machine this was developed on (Docker Desktop was not running). Do the first build on the server and check step 6.

## 1. Server

Any Linux VPS (Ubuntu 22.04/24.04 is assumed). Open ports **80** and **443** (and 22 for SSH). Nothing else.

```bash
# install Docker Engine + the compose plugin: https://docs.docker.com/engine/install/ubuntu/
sudo usermod -aG docker $USER   # log out and back in
```

## 2. DNS

Create an **A record** for your domain (for example `aasaan.example.com`) pointing at the server's public IP.
Caddy needs this to obtain the HTTPS certificate.

## 3. Get the code and configure

```bash
git clone <your repo url> aasaan && cd aasaan
cp .env.example .env
nano .env
```

Fill in `.env`:

| Variable | Needed | Notes |
|---|---|---|
| `GEMINI_API_KEY` | **yes** | Google AI Studio. Without it the app shows "No AI model is connected" and cannot build notebooks. |
| `AASAAN_DB` | optional | SQLite database path. Default: `data/aasaan.db` (in container: `/app/data/aasaan.db`; on ACA: `/app/local/aasaan.db`). Parent dir created on start. |
| `AASAAN_UPLOADS` | optional | Uploads directory path. Default: `data/uploads` (in container: `/app/data/uploads`; on ACA: `/mnt/files`). Created on start. |
| `AASAAN_DOMAIN` | yes (prod) | Your domain, e.g. `aasaan.example.com`. Unset = `localhost`. |
| `AASAAN_ADMIN_TOKEN` | **yes (prod)** | Long random string. Protects `/api/events` and `/api/admin/*`. Without it those are localhost-only. |
| `SARVAM_API_KEY` | optional | Indian-language chat, voice, translation. |
| `TYPESAFE_API_KEY` | optional | Jev: grading misconceptions and ranking resources. |
| `YOUTUBE_API_KEY` | optional | Video search. Without it (and without Gemini grounding) chapters have no videos. |
| `JINA_API_KEY`, `FIRECRAWL_API_KEY`, `OPENVERSE_CLIENT_ID`+`_SECRET` | optional | Firecrawl is the last page tier and a discovery fallback, capped per notebook; Openverse credentials raise image-search limits. |
| `AASAAN_CONTACT` | recommended | A URL or email put in the crawler's User-Agent so site owners can reach you. |
| `AASAAN_NB_PER_HOUR` | optional | Notebooks one IP may create per hour (default 12). |
| `AASAAN_CHAPTER_CONCURRENCY` | optional | Chapters built at once (default 2). Lower it if you hit rate limits. |
| `AASAAN_MAX_CALLS` | optional | Global cap on simultaneous model calls (default 4). |

Generate a token with: `openssl rand -hex 24`.

## 4. Start

```bash
docker compose up -d --build
docker compose ps          # app, caddy and backup should be "running"/"healthy"
```

## 5. Check the models (important)

```bash
curl -s https://YOUR_DOMAIN/api/health/models | python3 -m json.tool
docker compose logs app | grep aasaan | head -30
```

Every model must say `"status": "ok"`. A `failed` entry carries the exact error (wrong key, wrong model id, quota).
The app does **not** silently fall back: each fallback is recorded with its reason in the logs and in the `events`
table (`curl -H "X-Admin-Token: $TOKEN" https://YOUR_DOMAIN/api/events`).

## 6. Smoke test

Open `https://YOUR_DOMAIN`, type "I want to learn DSA". The notebook should open within about a minute with a
roadmap and graph, and the remaining chapters should fill in. If the image fails to build or the container is
unhealthy: `docker compose logs app`.

## Backups

### Docker Compose
The `backup` service writes `./backups/aasaan-YYYY-MM-DD.db` (SQLite online backup, safe while running) at start and
every 24 hours, and deletes backups older than 14 days. Copy that folder off the server regularly.

Restore:

```bash
docker compose stop app
docker run --rm -v hacktoberfest_aasaan-data:/data -v "$PWD/backups:/backups" alpine \
  sh -c 'cp /backups/aasaan-YYYY-MM-DD.db /data/aasaan.db && rm -f /data/aasaan.db-wal /data/aasaan.db-shm'
docker compose start app
```

(The volume name is `<project folder>_aasaan-data`; check with `docker volume ls`.)

### Azure Container Apps (ACA) & Multi-Container Deployments
On Azure Container Apps, the live SQLite database runs on an EmptyDir local volume (`/app/local/aasaan.db`) and backups persist to an Azure Files share (`/mnt/files/backups`).

1. **Pre-start Restore (`python -m app.restore`)**:
   - Runs as an init container before the app container starts.
   - If `/app/local/aasaan.db` already exists, it skips restore and exits 0.
   - If empty, it inspects `/mnt/files/backups`, verifies `PRAGMA integrity_check` on candidate backups (newest first), atomically copies the newest valid backup to `/app/local/aasaan.db`, and purges any stale `-wal` or `-shm` sidecars.
   - If no backups exist (initial deployment), it starts clean and exits 0.

2. **Continuous Online Backup (`python -m app.backup_loop`)**:
   - Runs as a sidecar or scheduled container.
   - Executes `Connection.backup` online copies into `/mnt/files/backups/aasaan-YYYY-MM-DD-HHMM.db.tmp`, runs `PRAGMA integrity_check`, and atomically renames valid backups to `.db`.
   - Prunes backups older than `AASAAN_BACKUP_KEEP_DAYS` (default: 14 days), while unconditionally keeping the newest 3 valid backups.
   - Configurable via `AASAAN_BACKUP_DIR`, `AASAAN_BACKUP_EVERY_MIN` (default: 5), and `AASAAN_BACKUP_KEEP_DAYS` (default: 14).
   - Also exposes `run_backup_once()` for programmatic or admin endpoint triggers.

## Updating

```bash
git pull
docker compose up -d --build
```

Unfinished chapters are re-queued automatically after a restart (jobs are stored in the database).

## Operations

- Logs: `docker compose logs -f app` (lines prefixed `[aasaan]`).
- Demo "kill the primary model": `curl -X POST -H "X-Admin-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"model":"gemma_31b"}' https://YOUR_DOMAIN/api/admin/kill` and `/api/admin/revive` to undo.
- Privacy: no accounts and no personal data are collected. A random learner id lives in the browser; memory (mistake labels, progress) stays in the local database. Uploaded files are stored under the data volume.
- Rate limits: set `AASAAN_NB_PER_HOUR` and `AASAAN_CHAPTER_CONCURRENCY` to match your Gemini quota (check it in AI Studio).

## Security Headers and Content Security Policy (CSP)

On container platforms without Caddy (such as Azure Container Apps), the FastAPI application applies security headers directly via `SecurityHeadersMiddleware`:
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `X-Frame-Options: SAMEORIGIN`
- `Permissions-Policy: camera=(), microphone=(), geolocation=()`
- `Strict-Transport-Security: max-age=31536000; includeSubDomains` (sent automatically whenever `X-Forwarded-Proto: https` is received)
- `Server`: stripped from all responses

### Moving from Report-Only to Enforce Mode
Content Security Policy is controlled by `AASAAN_CSP_MODE`:
- `report-only` (default): Injects `Content-Security-Policy-Report-Only` pointing `report-uri` to `POST /csp-report`. Browser violations are logged without breaking page execution.
- `enforce`: Injects `Content-Security-Policy` to actively block unauthorized origins.
- `off`: Disables CSP headers completely.

**Transition Workflow**:
1. Deploy with `AASAAN_CSP_MODE=report-only` (the default).
2. Monitor violation reports in the logs: `docker compose logs -f app | grep "\[csp-report\]"`.
3. Verify all necessary YouTube embeds, Google Fonts, and Wikimedia/Openverse images load cleanly without violations.
4. Set `AASAAN_CSP_MODE=enforce` in your container environment variables to activate enforcement.

## Server-Sent Events (SSE) and Ingress Timeout Resilience

Azure Container Apps (ACA) ingress cuts any HTTP connection exceeding 240 seconds. To survive proxy cuts without dropping real-time updates:
- **Planned Stream Close**: The `/api/notebooks/{nid}/stream` endpoint closes cleanly after ~200 seconds (`AASAAN_SSE_MAX_SECONDS`, default: 200, with small random jitter), sending a `retry: 2000` hint so the browser automatically reconnects after 2 seconds well before the 240-second cutoff.
- **Heartbeats**: The server emits `: keepalive` comments every 15 seconds to prevent intermediate reverse proxies from terminating idle connections.
- **Monotonic IDs & Replay Buffer**: Events carry monotonic `id:` headers backed by a per-notebook bounded in-memory buffer. Reconnecting clients supplying `Last-Event-ID` (or `?last_event_id=`) resume missed updates in order with zero duplicates or gaps.
- **Resync on Gap**: If a replica restarts or a client reconnects with an ID older than the buffer, the server sends `event: resync` instructing the client to refetch current state via `/api/notebooks/{nid}`.

## Reverse Proxy Client IP & Rate Limiting

On Azure Container Apps (ACA), the ingress Envoy proxy terminates client connections and **appends** the connecting client's IP to the `X-Forwarded-For` header. Because clients can send arbitrary `X-Forwarded-For` headers with forged leftmost entries, only the **rightmost** entry added by the trusted ingress platform is authoritative.

- **Configurable Trust Model**: Controlled by `AASAAN_TRUSTED_PROXY_HOPS` (default: `1`):
  - `0`: Trust no proxy headers; use socket peer IP directly.
  - `1` (default): Trust 1 proxy hop from the right (exact match for ACA ingress and Caddy in Docker Compose).
  - `N >= 1`: Takes the $N$-th entry from the right of `X-Forwarded-For`.
- **Strict Parsing & Fallback**: Header entries are stripped of whitespace and quotes, ports/brackets are safely stripped (`1.2.3.4:5678` -> `1.2.3.4`, `[2001:db8::1]:80` -> `2001:db8::1`), and validated against Python's `ipaddress` library. Malformed entries or missing headers safely fall back to the socket peer IP without throwing exceptions.
- **Uvicorn Flag Removal**: Uvicorn's `--proxy-headers` and `--forwarded-allow-ips "*"` flags have been removed. This prevents uvicorn from rewriting `request.client` based on spoofable leftmost values, centralizing all IP extraction in `get_client_ip(request)`.
- **IPv6 Prefix Bucketing**: Rate limits bucket IPv6 addresses by `/64` network prefix rather than individual `/128` addresses, preventing users from evading limits by rotating IPv6 interface addresses within their assigned prefix.
