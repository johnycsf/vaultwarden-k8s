#!/usr/bin/env bash
# Install / reconfigure Vaultwarden on Kubernetes (interactive).
# Re-run anytime to change StorageClass preference or replica count.
# Does NOT rotate ADMIN_TOKEN on re-run if the Secret already exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"

ui_banner "Vaultwarden" "Kubernetes - storage + replicas chosen interactively"
ui_steps_init 5

ui_step "Checking host dependencies"
ensure_host_deps k8s sqlite3 age zip unzip xz

ui_step "StorageClass"
configure_k8s_storage

ui_step "Replica count"
configure_k8s_replicas vaultwarden

ALREADY=false
if kubectl -n vaultwarden get deploy vaultwarden >/dev/null 2>&1; then
  ALREADY=true
  ui_info "Existing Vaultwarden Deployment found - refreshing manifests/replicas"
fi

DOMAIN="${DOMAIN:-}"
if [[ -z "${DOMAIN}" ]]; then
  if [[ "${ALREADY}" == true ]]; then
    DOMAIN="$(kubectl -n vaultwarden get secret vaultwarden -o jsonpath='{.data.domain}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
fi
if [[ -z "${DOMAIN}" ]]; then
  ui_info "Detecting a node address for DOMAIN (or set DOMAIN=https://vault.example.com)"
  NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  if [[ -z "${NODE_IP}" ]]; then
    ui_err "Could not detect a node IP. Re-run with DOMAIN set."
    exit 1
  fi
  DOMAIN="http://${NODE_IP}:8081"
fi
ui_ok "DOMAIN=${DOMAIN}"

ui_step "Applying manifests"
ui_run "kubectl apply" apply_manifest "${ROOT}/deploy.yaml"

TOKEN_FILE="${ROOT}/.admin-token"
if kubectl -n vaultwarden get secret vaultwarden >/dev/null 2>&1 && [[ "${ALREADY}" == true ]]; then
  ui_ok "Keeping existing vaultwarden Secret (admin token unchanged)"
  if [[ ! -f "${TOKEN_FILE}" ]]; then
    EXISTING_TOKEN="$(kubectl -n vaultwarden get secret vaultwarden -o jsonpath='{.data.admin-token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -n "${EXISTING_TOKEN}" ]]; then
      umask 077
      printf '%s\n' "${EXISTING_TOKEN}" >"${TOKEN_FILE}"
      ui_ok "Wrote existing admin token to ${TOKEN_FILE}"
    fi
  fi
else
  ADMIN_TOKEN="$(openssl rand -base64 48 | tr -d '\n')"
  kubectl -n vaultwarden create secret generic vaultwarden \
    --from-literal=domain="${DOMAIN}" \
    --from-literal=admin-token="${ADMIN_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  umask 077
  printf '%s\n' "${ADMIN_TOKEN}" >"${TOKEN_FILE}"
  ui_ok "Generated admin token -> ${TOKEN_FILE}"
  ui_run "Restart to pick up Secret" kubectl -n vaultwarden rollout restart deployment/vaultwarden
fi

ui_step "Scaling and waiting"
apply_saved_replicas vaultwarden
ui_run "Wait for rollout" kubectl -n vaultwarden rollout status deployment/vaultwarden --timeout=180s

echo
ui_ok "Vaultwarden ready (replicas=${CHOSEN_REPLICAS:-1}, storage=${CHOSEN_STORAGE_CLASS:-})"
ui_info "URL:   ${UI_BOLD}${DOMAIN}${UI_RESET}"
ui_info "Admin: ${UI_BOLD}${DOMAIN}/admin${UI_RESET}"
ui_info "Token: ${TOKEN_FILE}"
ui_info "After first account: kubectl -n vaultwarden set env deployment/vaultwarden SIGNUPS_ALLOWED=false"
ui_info "Re-run ./manage.sh anytime to change replicas or storage preference"
