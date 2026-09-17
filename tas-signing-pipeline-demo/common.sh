#!/usr/bin/env bash
#
# Shared config and helpers for tas-signing-demo. Sourced by install-infra.sh,
# run-demo.sh, cleanup-infra.sh, and cleanup-demo.sh.  It assumes the caller
# has already set -euo pipefail and cd'd to the repo root.

# ---- Config -----------------------------------------------------------
ZOT_NAMESPACE="${ZOT_NAMESPACE:-zot-tas-demo}"
TAS_OPERATOR_NAMESPACE="${TAS_OPERATOR_NAMESPACE:-securesign-system}"
TAS_NAMESPACE="${TAS_NAMESPACE:-rhtas-demo}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-tas-demo}"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak-system}"
# fixed: policy-controller-operator's own admission webhook
# (validation.policycontrollers.rhtas.charts.redhat.com) hardcodes this as the
# only namespace a PolicyController CR may be created in.
POLICY_CONTROLLER_NAMESPACE="policy-controller-operator"

OCP_VERSION="${OCP_VERSION:-}"         # autodetected if unset, e.g. "4.21"
MCP_TIMEOUT="${MCP_TIMEOUT:-3600}"
CSV_TIMEOUT="${CSV_TIMEOUT:-900}"

RHTAS_OPERATOR_CHANNEL="${RHTAS_OPERATOR_CHANNEL:-stable-v1.4}"
POLICY_CONTROLLER_CHANNEL="${POLICY_CONTROLLER_CHANNEL:-stable-v1.0}"

SIGNER_USERNAME="${SIGNER_USERNAME:-demo}"
SIGNER_EMAIL="${SIGNER_EMAIL:-demo@example.com}"
SIGNER_PASSWORD="${SIGNER_PASSWORD:-password}"
SIGNER_FIRST_NAME="${SIGNER_FIRST_NAME:-Demo}"
SIGNER_LAST_NAME="${SIGNER_LAST_NAME:-User}"

WRONG_IDENTITY_USERNAME="${WRONG_IDENTITY_USERNAME:-demo-other}"
WRONG_IDENTITY_EMAIL="${WRONG_IDENTITY_EMAIL:-demo-other@example.com}"
WRONG_IDENTITY_PASSWORD="${WRONG_IDENTITY_PASSWORD:-password}"

# This cosign version aligns with the policy controller, the next version will
# introduce support for cosign 3.x.
COSIGN_VERSION="${COSIGN_VERSION:-1.3.7}"
COSIGN_SRC_IMAGE="${COSIGN_SRC_IMAGE:-registry.redhat.io/rhtas/cosign-rhel9:${COSIGN_VERSION}}"
COSIGN_ZOT_REPO="tools/cosign"

CURL_VERSION="${CURL_VERSION:-8.22.0}"
CURL_SRC_IMAGE="${CURL_SRC_IMAGE:-docker.io/curlimages/curl:${CURL_VERSION}}"
CURL_ZOT_REPO="tools/curl"

SAMPLE_APP_REPO="rhtas-demo/sample-app"
SAMPLE_APP_TAG="demo"
UNSIGNED_APP_REPO="rhtas-demo/unsigned-app"
WRONG_IDENTITY_APP_REPO="rhtas-demo/wrong-identity-app"
UNSIGNED_SRC_IMAGE="${UNSIGNED_SRC_IMAGE:-docker.io/library/busybox:latest}"
BUSYBOX_ZOT_REPO="tools/busybox"

OIDC_CLIENT_ID="trusted-artifact-signer"

# Namespace label the policy-controller webhook uses to opt a namespace into
# admission checks.
POLICY_NAMESPACE_LABEL="${POLICY_NAMESPACE_LABEL:-policy.rhtas.com/include=true}"

OC_MIRROR_EXTRA_ARGS="${OC_MIRROR_EXTRA_ARGS:-}"
OC_MIRROR_WORKSPACE_DIR="${OC_MIRROR_WORKSPACE_DIR:-oc-mirror-workspace}"

ASSUME_YES="${ASSUME_YES:-0}"

# ---- Helpers ------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$1" >&2; }
section() { printf '\n' >&2; log "$1"; }
die() { echo "error: $1" >&2; exit 1; }

require_bin() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"
}

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# `oc delete <resource> -n <ns> --ignore-not-found` only suppresses "resource
# not found".  If the namespace itself was never created, the delete still
# errors out and set -e kills the script. Guard namespaced deletes with this.
ns_exists() { oc get namespace "$1" >/dev/null 2>&1; }

# oc wait errors immediately with NotFound if the resource doesn't exist.
# It doesn't wait for creation, only for a condition on an already-existing
# resource. Poll for existence first.
wait_for_crd() {
    local crd="$1" timeout="${2:-300}" waited=0
    until oc get "crd/${crd}" >/dev/null 2>&1; do
        if (( waited >= timeout )); then
            die "timed out waiting for CRD ${crd} to be created"
        fi
        sleep 5
        waited=$((waited + 5))
    done
    oc wait --for condition=Established --timeout=60s "crd/${crd}"
}

discover_route() {
    local namespace="$1" name="$2"
    oc get route -n "$namespace" "$name" -o jsonpath='{.spec.host}' 2>/dev/null || true
}

discover_ingress_host() {
    local namespace="$1" name="$2"
    oc get ingress -n "$namespace" "$name" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true
}

wait_for_deployment_available() {
    local namespace="$1" name="$2" timeout="${3:-300s}"
    oc wait --for=condition=Available "deployment/${name}" -n "$namespace" --timeout="$timeout"
}

wait_for_keycloak_ready() {
    local namespace="$1" name="$2" timeout="${3:-600}" waited=0 ready
    while (( waited < timeout )); do
        ready="$(oc get "keycloak.keycloak.org/${name}" -n "$namespace" -o jsonpath='{.status.ready}' 2>/dev/null || true)"
        [[ "$ready" == "true" ]] && return 0
        sleep 10
        waited=$((waited + 10))
    done
    die "keycloak.keycloak.org/${name} did not become ready within ${timeout}s (last status.ready: ${ready:-unknown})"
}

wait_for_catalog_source_ready() {
    local name="$1" namespace="$2" waited=0 state
    log "waiting for CatalogSource/${name} (ns ${namespace}) to report READY"
    while (( waited < 300 )); do
        state="$(oc get catalogsource "$name" -n "$namespace" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)"
        [[ "$state" == "READY" ]] && { log "CatalogSource is READY"; return 0; }
        sleep 10
        waited=$((waited + 10))
    done
    die "CatalogSource/${name} did not become READY within 300s (last state: ${state:-unknown})"
}

wait_for_cip_conversion_ready() {
    local svc_ns="$1" svc_name="${2:-webhook}" timeout="${3:-300}" waited=0
    local crd="clusterimagepolicies.policy.sigstore.dev"
    local cur_name cur_ns ca_bundle endpoints
    while (( waited < timeout )); do
        cur_name="$(oc get "crd/${crd}" -o jsonpath='{.spec.conversion.webhook.clientConfig.service.name}' 2>/dev/null || true)"
        cur_ns="$(oc get "crd/${crd}" -o jsonpath='{.spec.conversion.webhook.clientConfig.service.namespace}' 2>/dev/null || true)"
        ca_bundle="$(oc get "crd/${crd}" -o jsonpath='{.spec.conversion.webhook.clientConfig.caBundle}' 2>/dev/null || true)"
        endpoints="$(oc get endpoints "$svc_name" -n "$svc_ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
        if [[ "$cur_name" == "$svc_name" && "$cur_ns" == "$svc_ns" && -n "$ca_bundle" && -n "$endpoints" ]]; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    die "ClusterImagePolicy conversion webhook clientConfig did not settle on ${svc_name}.${svc_ns} with a ready endpoint within ${timeout}s, check 'oc get crd ${crd} -o yaml' and 'oc get endpoints ${svc_name} -n ${svc_ns}'"
}

wait_for_csv_succeeded() {
    local package="$1" waited=0 csv phase
    log "waiting for Subscription/${package} to resolve an installed CSV"
    while (( waited < CSV_TIMEOUT )); do
        csv="$(oc get subscription "$package" -n "$TAS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
        [[ -n "$csv" ]] && break
        sleep 10
        waited=$((waited + 10))
    done
    [[ -n "${csv:-}" ]] || die "Subscription/${package} did not resolve an installed CSV within ${CSV_TIMEOUT}s"

    log "waiting for CSV/${csv} to reach Succeeded"
    waited=0
    while (( waited < CSV_TIMEOUT )); do
        phase="$(oc get csv "$csv" -n "$TAS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        [[ "$phase" == "Succeeded" ]] && { log "CSV/${csv} Succeeded"; return 0; }
        sleep 15
        waited=$((waited + 15))
    done
    die "CSV/${csv} did not reach Succeeded within ${CSV_TIMEOUT}s (last phase: ${phase:-unknown})"
}
