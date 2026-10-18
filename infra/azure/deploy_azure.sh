#!/usr/bin/env bash
# Deploy Aasaan to Azure Container Apps
# Works in Azure Cloud Shell, WSL, and Git Bash on Windows.
set -euo pipefail

# Trap unexpected errors and print rollback guidance
on_error() {
  local exit_code="$1"
  local line_no="$2"
  echo ""
  echo "======================================================================"
  echo "ERROR: Deployment failed at line ${line_no} (exit code ${exit_code})"
  echo "======================================================================"
  if [ -n "${PREV_REVISION:-}" ]; then
    echo "To roll back to previous active revision (${PREV_REVISION}):"
    echo "  az containerapp revision activate -g \"${RG}\" -n \"${APP}\" --revision \"${PREV_REVISION}\""
    echo "  az containerapp revision set-mode -g \"${RG}\" -n \"${APP}\" --mode Single"
  else
    echo "Check revision history:"
    echo "  az containerapp revision list -g \"${RG:-rg-aasaan}\" -n \"${APP:-aasaan}\" -o table"
  fi
  echo "Check container logs:"
  echo "  az containerapp logs show -g \"${RG:-rg-aasaan}\" -n \"${APP:-aasaan}\" --container app --tail 50"
  echo "======================================================================"
  rm -f infra/azure/app.yaml
  exit "${exit_code}"
}
trap 'on_error $? $LINENO' ERR

# -----------------------------------------------------------------------------
# a) Check prerequisites and required variables
# -----------------------------------------------------------------------------
command -v az >/dev/null 2>&1 || { echo "ERROR: 'az' CLI is required but not installed." >&2; exit 1; }
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run 'az login' first." >&2; exit 1; }

# Configuration variables (override via environment)
RG="${RG:-rg-aasaan}"
ENV_NAME="${ENV_NAME:-aasaan-env}"
APP="${APP:-aasaan}"
ACR="${ACR:-}"
AASAAN_CSP_MODE="${AASAAN_CSP_MODE:-report-only}"
AASAAN_CONTACT="${AASAAN_CONTACT:-admin@aasaan.local}"

if [ -z "$ACR" ]; then
  echo "ERROR: ACR variable must be set (name of Azure Container Registry)." >&2
  exit 1
fi

# Secret variables check (never echo these)
REQUIRED_SECRETS=("GEMINI_API_KEY" "AASAAN_ADMIN_TOKEN")
for sec in "${REQUIRED_SECRETS[@]}"; do
  if [ -z "${!sec:-}" ]; then
    echo "ERROR: Required environment variable $sec is not set." >&2
    exit 1
  fi
done

# Optional secrets: supply placeholder if unset so ACA YAML secret references resolve
export SARVAM_API_KEY="${SARVAM_API_KEY:-placeholder}"
export TYPESAFE_API_KEY="${TYPESAFE_API_KEY:-placeholder}"
export YOUTUBE_API_KEY="${YOUTUBE_API_KEY:-placeholder}"
export FIRECRAWL_API_KEY="${FIRECRAWL_API_KEY:-placeholder}"

echo "Fetching environment details for $ENV_NAME and credentials for $ACR..."
ENV_ID=$(az containerapp env show -g "$RG" -n "$ENV_NAME" --query id -o tsv)
ACR_PW=$(az acr credential show -n "$ACR" --query "passwords[0].value" -o tsv)
export ENV_ID ACR_PW

TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%s)
export TAG ACR RG APP ENV_NAME AASAAN_CSP_MODE AASAAN_CONTACT

# -----------------------------------------------------------------------------
# b) Check if app exists and trigger pre-deployment backup
# -----------------------------------------------------------------------------
APP_EXISTS=false
PREV_REVISION=""
PREV_FQDN=""

if az containerapp show -g "$RG" -n "$APP" >/dev/null 2>&1; then
  APP_EXISTS=true
  PREV_REVISION=$(az containerapp show -g "$RG" -n "$APP" --query "properties.latestRevisionName" -o tsv 2>/dev/null || true)
  PREV_FQDN=$(az containerapp show -g "$RG" -n "$APP" --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null || true)
fi

if [ "$APP_EXISTS" = "true" ] && [ -n "$PREV_FQDN" ]; then
  echo "Existing deployment detected (revision: ${PREV_REVISION})."
  echo "Triggering pre-deployment backup via POST https://${PREV_FQDN}/api/admin/backup..."
  set +e
  BACKUP_OUT=$(curl -s -f -k -X POST "https://${PREV_FQDN}/api/admin/backup" \
    -H "X-Admin-Token: ${AASAAN_ADMIN_TOKEN}" \
    --max-time 30 2>/dev/null)
  CURL_EXIT=$?
  set -e
  if [ $CURL_EXIT -eq 0 ] && [ -n "$BACKUP_OUT" ]; then
    echo "Pre-deployment backup completed: $BACKUP_OUT"
  else
    echo "Notice: Could not reach /api/admin/backup on existing deployment; proceeding."
  fi
else
  echo "First deployment detected (no existing container app)."
fi

# -----------------------------------------------------------------------------
# c) Build container image via Azure Container Registry
# -----------------------------------------------------------------------------
echo "Building container image ${ACR}.azurecr.io/aasaan:${TAG} via az acr build..."
az acr build -r "$ACR" -t "aasaan:${TAG}" .

# -----------------------------------------------------------------------------
# d) Render YAML and create or update container app
# -----------------------------------------------------------------------------
FQDN="${PREV_FQDN:-localhost}"
export FQDN

PYTHON_BIN="python"
if ! command -v python >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
fi

echo "Rendering deployment configuration..."
$PYTHON_BIN infra/azure/render.py infra/azure/app.template.yaml infra/azure/app.yaml

if [ "$APP_EXISTS" = "true" ]; then
  echo "Updating container app ${APP} with revision tag ${TAG}..."
  az containerapp update -g "$RG" -n "$APP" --yaml infra/azure/app.yaml
else
  echo "Creating container app ${APP} with tag ${TAG}..."
  az containerapp create -g "$RG" -n "$APP" --yaml infra/azure/app.yaml
fi
rm -f infra/azure/app.yaml

ACTUAL_FQDN=$(az containerapp show -g "$RG" -n "$APP" --query "properties.configuration.ingress.fqdn" -o tsv)

# If this was initial deploy, re-render and update with the real FQDN for AASAAN_DOMAIN
if [ "$FQDN" != "$ACTUAL_FQDN" ]; then
  echo "Configuring assigned FQDN ($ACTUAL_FQDN)..."
  FQDN="$ACTUAL_FQDN"
  export FQDN
  $PYTHON_BIN infra/azure/render.py infra/azure/app.template.yaml infra/azure/app.yaml
  az containerapp update -g "$RG" -n "$APP" --yaml infra/azure/app.yaml
  rm -f infra/azure/app.yaml
fi

# -----------------------------------------------------------------------------
# e) Wait for new revision and verify health probes with retries
# -----------------------------------------------------------------------------
echo "Verifying health probes on https://${ACTUAL_FQDN}..."
HEALTHY=false
for attempt in $(seq 1 30); do
  set +e
  HTTP_LIVENESS=$(curl -s -k -o /dev/null -w "%{http_code}" --max-time 5 "https://${ACTUAL_FQDN}/health" 2>/dev/null)
  HTTP_READINESS=$(curl -s -k -o /dev/null -w "%{http_code}" --max-time 5 "https://${ACTUAL_FQDN}/health/ready" 2>/dev/null)
  set -e
  if [ "$HTTP_LIVENESS" = "200" ] && [ "$HTTP_READINESS" = "200" ]; then
    HEALTHY=true
    echo "Health probes passed! (/health=200, /health/ready=200)"
    break
  fi
  echo "Waiting for container readiness (attempt ${attempt}/30, status: liveness=${HTTP_LIVENESS}, readiness=${HTTP_READINESS})..."
  sleep 6
done

if [ "$HEALTHY" != "true" ]; then
  echo "ERROR: Health checks timed out after 180 seconds." >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# f) Smoke test: create a learner session and confirm backup endpoint
# -----------------------------------------------------------------------------
echo "Running smoke test on deployed application..."
SMOKE_SESSION=$(curl -s -k -f -X POST "https://${ACTUAL_FQDN}/api/session/open" \
  -H "Content-Type: application/json" \
  -d '{"learner_id":"deploy-smoke-test"}' 2>/dev/null || echo "failed")
echo "Session smoke test: ${SMOKE_SESSION}"

SMOKE_BACKUP=$(curl -s -k -f -X POST "https://${ACTUAL_FQDN}/api/admin/backup" \
  -H "X-Admin-Token: ${AASAAN_ADMIN_TOKEN}" 2>/dev/null || echo "failed")
echo "Backup smoke test: ${SMOKE_BACKUP}"

echo ""
echo "======================================================================"
echo "DEPLOYMENT SUCCESSFUL!"
echo "App URL: https://${ACTUAL_FQDN}"
echo "Revision: $(az containerapp show -g "$RG" -n "$APP" --query "properties.latestRevisionName" -o tsv)"
echo "======================================================================"
