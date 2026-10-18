# Deploying Aasaan on Azure Container Apps (ACA)

This runbook covers deploying Aasaan to Azure Container Apps as a single container application with zero-downtime backups, safe SQLite persistence, and non-root security.

For the Docker Compose single-server deployment guide, see [DEPLOY.md](DEPLOY.md).

---

## 1. Architecture Overview

Because Azure Container Apps is a serverless container platform without local attached block storage, Aasaan uses a specialized architecture designed for single-instance SQLite applications:

```
+-----------------------------------------------------------------------------------+
| Azure Container App Replica (minReplicas=1, maxReplicas=1, Single Revision Mode)  |
|                                                                                   |
|  +---------------------------+                                                    |
|  | Init Container: restore   |  (Runs python -m app.restore once before start)     |
|  +-------------+-------------+                                                    |
|                |                                                                  |
|                v (copies newest valid backup)                                     |
|  +---------------------------+      +---------------------------+                 |
|  | Main Container: app       |      | Sidecar: backup           |                 |
|  | Port 8000 (FastAPI engine)|      | (python -m app.backup_loop)                |
|  +-------------+-------------+      +-------------+-------------+                 |
|                |                                  |                               |
|                | (reads/writes)                   | (online backup every 5 min)   |
|                v                                  v                               |
|  +---------------------------+      +---------------------------+                 |
|  | EmptyDir Volume           |      | Azure Files Volume        |                 |
|  | /app/local/aasaan.db      |      | /mnt/files/backups        |                 |
|  | (Fast local temporary disk|      | /mnt/files/uploads        |                 |
|  |  no network file locking) |      | (Persistent SMB Share)    |                 |
|  +---------------------------+      +---------------------------+                 |
+-----------------------------------------------------------------------------------+
```

- **Live Database**: SQLite resides on an `EmptyDir` volume at `/app/local/aasaan.db`. This provides local disk performance and avoid SQLite locking/WAL corruption over network filesystems.
- **Restore Init Container**: Runs `python -m app.restore` before the app starts. If `/app/local/aasaan.db` is missing, it verifies and copies the newest valid backup from `/mnt/files/backups`.
- **Backup Sidecar**: Runs `python -m app.backup_loop` alongside the app, performing an online non-blocking `sqlite3.backup` every 5 minutes to Azure Files.
- **Uploads**: Stored directly on Azure Files at `/mnt/files/uploads`.
- **Scale**: Strictly `minReplicas: 1` and `maxReplicas: 1` in single-revision mode (SQLite supports only one active writer).

---

## 2. Prerequisites for Windows Users

You can deploy from **Git Bash**, **WSL2 (Ubuntu)**, or **PowerShell / Azure Cloud Shell**.

1. **Install Azure CLI**:
   ```powershell
   winget install -e --id Microsoft.AzureCLI
   ```
   Or download the MSI installer from [Microsoft Docs](https://learn.microsoft.com/cli/azure/install-azure-cli-windows).

2. **Login and Register Providers**:
   ```bash
   az login
   az extension add --name containerapp --upgrade -y
   az provider register --namespace Microsoft.App
   az provider register --namespace Microsoft.OperationalInsights
   ```

3. **Verify Python**: Python 3.10+ must be installed locally to run the template rendering script (`python --version`).

---

## 3. One-Time Resource Creation

Set your variables in your shell (adjust region if desired):

```bash
RG=rg-aasaan
LOC=centralindia            # or southindia, eastus, westeurope
ENV_NAME=aasaan-env
APP=aasaan
ACR=aasaanacr$RANDOM        # globally unique alphanumeric registry name
SA=aasaanstore$RANDOM       # globally unique storage account name (3-24 lowercase letters/numbers)
SHARE=aasaan-data
```

### 3.1 Create Resource Group, Registry, and ACA Environment
```bash
az group create -n "$RG" -l "$LOC"
az acr create -g "$RG" -n "$ACR" --sku Basic --admin-enabled true
az containerapp env create -g "$RG" -n "$ENV_NAME" -l "$LOC"
```

### 3.2 Create Storage Account and Azure Files Share
```bash
az storage account create -g "$RG" -n "$SA" -l "$LOC" --sku Standard_LRS --kind StorageV2
az storage share-rm create --resource-group "$RG" --storage-account "$SA" --name "$SHARE" --quota 10
SAKEY=$(az storage account keys list -g "$RG" -n "$SA" --query "[0].value" -o tsv)
```

### 3.3 Link Storage to Container Apps Environment
Mount options ensure non-root container UID `10001` has full read/write permissions:
```bash
az containerapp env storage set -g "$RG" -n "$ENV_NAME" --storage-name aasaanfiles \
  --storage-type AzureFile --azure-file-account-name "$SA" \
  --azure-file-account-key "$SAKEY" --azure-file-share-name "$SHARE" --access-mode ReadWrite
```

---

## 4. First Deployment

### Option A: Automated Script (Recommended)
Export required API keys and run the deployment script:

```bash
export RG="rg-aasaan"
export ENV_NAME="aasaan-env"
export APP="aasaan"
export ACR="<your-acr-name>"
export GEMINI_API_KEY="AIzaSy..."
export AASAAN_ADMIN_TOKEN="$(openssl rand -hex 24)"
export AASAAN_CONTACT="admin@yourdomain.com"
export AASAAN_CSP_MODE="report-only"

# Optional keys (defaults to placeholder if unset):
# export SARVAM_API_KEY="..."
# export TYPESAFE_API_KEY="..."
# export YOUTUBE_API_KEY="..."
# export FIRECRAWL_API_KEY="..."

bash infra/azure/deploy_azure.sh
```

### Option B: Manual Step-by-Step

1. **Build image in Azure Container Registry**:
   ```bash
   TAG=$(git rev-parse --short HEAD)
   az acr build -r "$ACR" -t "aasaan:$TAG" .
   ```

2. **Retrieve credentials**:
   ```bash
   ENV_ID=$(az containerapp env show -g "$RG" -n "$ENV_NAME" --query id -o tsv)
   ACR_PW=$(az acr credential show -n "$ACR" --query "passwords[0].value" -o tsv)
   ```

3. **Render YAML template**:
   ```bash
   export ENV_ID ACR ACR_PW TAG GEMINI_API_KEY AASAAN_ADMIN_TOKEN FQDN=localhost AASAAN_CONTACT AASAAN_CSP_MODE
   python infra/azure/render.py infra/azure/app.template.yaml infra/azure/app.yaml
   ```

4. **Create the container app**:
   ```bash
   az containerapp create -g "$RG" -n "$APP" --yaml infra/azure/app.yaml
   rm infra/azure/app.yaml
   ```

5. **Update FQDN**:
   ```bash
   FQDN=$(az containerapp show -g "$RG" -n "$APP" --query properties.configuration.ingress.fqdn -o tsv)
   export FQDN
   python infra/azure/render.py infra/azure/app.template.yaml infra/azure/app.yaml
   az containerapp update -g "$RG" -n "$APP" --yaml infra/azure/app.yaml
   rm infra/azure/app.yaml
   ```

---

## 5. Updates and Upgrades

Zero-downtime updates are triggered automatically before revision shifts:

1. **Pre-deployment backup**: Before pushing new code, call the admin backup endpoint:
   ```bash
   curl -X POST "https://$FQDN/api/admin/backup" -H "X-Admin-Token: $AASAAN_ADMIN_TOKEN"
   ```
2. **Build and Update**:
   ```bash
   TAG=$(git rev-parse --short HEAD)
   az acr build -r "$ACR" -t "aasaan:$TAG" .
   python infra/azure/render.py infra/azure/app.template.yaml infra/azure/app.yaml
   az containerapp update -g "$RG" -n "$APP" --yaml infra/azure/app.yaml
   rm infra/azure/app.yaml
   ```
   *(The automated script `deploy_azure.sh` executes all these steps automatically).*

---

## 6. Rollback

If a new revision fails or introduces issues, roll back immediately:

```bash
# 1. List revisions
az containerapp revision list -g "$RG" -n "$APP" -o table

# 2. Activate previous healthy revision
az containerapp revision activate -g "$RG" -n "$APP" --revision "<PREVIOUS_REVISION_NAME>"
```

---

## 7. Restoring from a Backup

1. **Automatic Restore on Startup**:
   If the replica restarts or crashes, the init container (`app.restore`) automatically checks `/mnt/files/backups`, validates the newest backup's SQLite integrity, and restores it to `/app/local/aasaan.db`.

2. **Triggering Immediate Force Backup**:
   ```bash
   curl -i -X POST "https://$FQDN/api/admin/backup" -H "X-Admin-Token: $AASAAN_ADMIN_TOKEN"
   ```
   Returns:
   ```json
   {"ok": true, "file": "aasaan-2026-10-18-0924.db", "size": 163840, "duration": 0.042}
   ```

3. **Restoring a Specific Historical Backup**:
   Connect via Azure Portal or Azure CLI, copy the chosen historical backup over the newest file in the Azure Files share, and restart the revision:
   ```bash
   az containerapp revision restart -g "$RG" -n "$APP" --revision "$(az containerapp show -g "$RG" -n "$APP" --query properties.latestRevisionName -o tsv)"
   ```

---

## 8. Cost Management & Budget Alerts

### Consumption Plan Cost Note
- Azure Container Apps Consumption plan provides a monthly free grant: **180,000 vCPU-seconds, 360,000 GiB-seconds, and 2 million requests**.
- With `minReplicas=1` (always-on single instance sized at 0.75 vCPU and 1.5 GiB across app + sidecar), active usage will exceed the free tier. Replicas run at a discounted "idle" rate when not serving requests and standard rate when active.
- Typical monthly cost is low ($10 - $25/month depending on region).

### Setting a Budget Alert
To avoid unexpected charges:
1. Open the [Azure Portal](https://portal.azure.com).
2. Navigate to **Cost Management + Billing** $\rightarrow$ **Budgets**.
3. Create a budget for resource group `rg-aasaan` (e.g. $25/month).
4. Set an alert threshold at 80% and 100% to notify your email address.

Or create via Azure CLI:
```bash
az consumption budget create -g "$RG" --budget-name "aasaan-monthly-budget" \
  --amount 25 --time-grain Monthly --start-date "$(date +%Y-%m-01)" \
  --end-date "$(date -d '+1 year' +%Y-%m-01)"
```

---

## 9. Acceptance Checklist (Verification)

Confirm your deployment meets all 9 acceptance criteria:

1. **Build & Liveness**: `az acr build` succeeds and `curl https://$FQDN/health` returns `{"ok": true}`.
2. **HTTPS Ingress**: App is accessible via HTTPS at `https://<app>.<region>.azurecontainerapps.io`.
3. **Model Health & Admin Auth**:
   - `curl https://$FQDN/api/health/models` shows configured models as `ok`.
   - `curl -i -X POST https://$FQDN/api/admin/backup` without token returns `403 Forbidden`.
4. **End-to-End Notebooks & SSE Reconnect**:
   - Create a notebook from the web interface.
   - Live generation streams continuous progress.
   - Long-running generation cleanly survives across the 240-second ACA proxy cutoff via client reconnection.
5. **Replica Restart Persistence**:
   - Restart the replica: `az containerapp revision restart -g $RG -n $APP`.
   - Reopen the app: the database is restored by the init container, notebooks remain intact, and uploaded files persist.
6. **Corrupt Backup Fallback**:
   - If the newest backup file is damaged, `python -m app.restore` automatically falls back to the preceding valid backup.
7. **Rate Limiting & Client IP**:
   - Rate limiting correctly identifies the client IP from the rightmost `X-Forwarded-For` entry added by ACA ingress.
   - Spoofed headers do not bypass limits.
8. **Automated Rollback**:
   - Deploying an invalid image tag triggers rollback instructions, allowing fast reversion.
9. **Observability & Budget**:
   - Logs stream live via `az containerapp logs show -g $RG -n $APP --container app --follow`.
   - Budget alert is configured in Azure Cost Management.
