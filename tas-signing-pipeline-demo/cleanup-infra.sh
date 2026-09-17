#!/usr/bin/env bash
#
# Tears down everything install-infra.sh created (and, for good measure, the
# ClusterImagePolicy and TrustRoot run-demo.sh creates).
#
# WARNING: deleting the ImageDigestMirrorSet rolls every MachineConfigPool on
# the cluster again (cordon, drain, reboot, one node at a time), same as
# applying it did.
#
# Usage:
#   ./cleanup-infra.sh [--yes]
set -euo pipefail
cd "$(dirname "$0")"

for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
    esac
done
source ./common.sh

wait_for_mcp_rollout() {
    log "waiting up to ${MCP_TIMEOUT}s for MachineConfigPool rollout..."
    local waited=0 statuses
    while (( waited < MCP_TIMEOUT )); do
        statuses="$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.conditions[?(@.type=="Updated")].status}{"  "}{end}')"
        if [[ "$statuses" == *False* || "$statuses" == *Unknown* || -z "$statuses" ]]; then
            log "MCP rollout in progress: ${statuses:-<no pools reported>}"
            sleep 30
            waited=$((waited + 30))
        else
            log "all MachineConfigPools updated: ${statuses}"
            return 0
        fi
    done
    log "WARNING: MCP rollout did not confirm completion within ${MCP_TIMEOUT}s, check 'oc get mcp' manually"
}

oc whoami >/dev/null 2>&1 || die "not logged in (run 'oc login' first)"
log "logged in to $(oc whoami --show-server) as $(oc whoami)"

log "==> Deleting ClusterImagePolicy and demo namespace ${DEMO_NAMESPACE}"
if oc get crd clusterimagepolicies.policy.sigstore.dev >/dev/null 2>&1; then
    oc delete clusterimagepolicies.policy.sigstore.dev tas-demo-policy --ignore-not-found
fi
if oc get crd trustroots.policy.sigstore.dev >/dev/null 2>&1; then
    oc delete trustroots.policy.sigstore.dev tas-demo-trust-root --ignore-not-found
fi
oc delete namespace "$DEMO_NAMESPACE" --ignore-not-found

log "==> Deleting Securesign instance and namespace ${TAS_NAMESPACE}"
oc delete securesign trusted-artifact-signer -n "$TAS_NAMESPACE" --ignore-not-found
oc delete namespace "$TAS_NAMESPACE" --ignore-not-found

log "==> Deleting PolicyController CR and namespace ${POLICY_CONTROLLER_NAMESPACE}"
oc delete policycontroller policycontroller-sample -n "$POLICY_CONTROLLER_NAMESPACE" --ignore-not-found --timeout=120s
oc delete namespace "$POLICY_CONTROLLER_NAMESPACE" --ignore-not-found

log "==> Deleting rhtas-operator + policy-controller-operator subscriptions"
for package in rhtas-operator policy-controller-operator; do
    csv="$(oc get subscription "$package" -n "$TAS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    oc delete subscription "$package" -n "$TAS_OPERATOR_NAMESPACE" --ignore-not-found
    [[ -n "$csv" ]] && oc delete csv "$csv" -n "$TAS_OPERATOR_NAMESPACE" --ignore-not-found
done
oc delete namespace "$TAS_OPERATOR_NAMESPACE" --ignore-not-found

log "==> Deleting the oc-mirror-generated CatalogSource"
CLUSTER_RESOURCES_DIR="${OC_MIRROR_WORKSPACE_DIR}/working-dir/cluster-resources"
CATSRC_FILE="$(ls "${CLUSTER_RESOURCES_DIR}"/cs-*.yaml 2>/dev/null | tail -1 || true)"
if [[ -n "$CATSRC_FILE" ]]; then
    oc delete -f "$CATSRC_FILE" --ignore-not-found
else
    log "no ${CLUSTER_RESOURCES_DIR}/cs-*.yaml found locally, delete the CatalogSource manually if it still exists (oc get catalogsource -n openshift-marketplace)"
fi

IDMS_FILE="$(ls "${CLUSTER_RESOURCES_DIR}"/idms-*.yaml 2>/dev/null | tail -1 || true)"
if [[ -n "$IDMS_FILE" ]]; then
    echo
    echo "About to delete an ImageDigestMirrorSet. This rolls EVERY MachineConfigPool"
    echo "on the cluster again (cordon, drain, reboot, one node at a time)."
    if confirm "Delete ${IDMS_FILE} and roll all nodes on $(oc whoami --show-server)?"; then
        oc delete -f "$IDMS_FILE" --ignore-not-found
        wait_for_mcp_rollout
    else
        log "leaving the ImageDigestMirrorSet in place (registry.redhat.io/rhtas/* will keep resolving to zot until you remove it)"
    fi
else
    log "no ${CLUSTER_RESOURCES_DIR}/idms-*.yaml found locally, remove it manually if it still exists (oc get imagedigestmirrorset)"
fi

log "==> Deleting Keycloak (namespace ${KEYCLOAK_NAMESPACE}); this affects anything else on the cluster using it (e.g. tas-conforma demos)"
oc delete keycloakusers.keycloak.org,keycloakrealms.keycloak.org,keycloakclients.keycloak.org \
    --all -n "$KEYCLOAK_NAMESPACE" --ignore-not-found --timeout=120s
oc delete namespace "$KEYCLOAK_NAMESPACE" --ignore-not-found

log "==> Deleting OpenShift Pipelines operator"
if oc get console.operator cluster -o jsonpath='{.spec.plugins}' 2>/dev/null | grep -q pipelines-console-plugin; then
    log "removing pipelines-console-plugin from console.operator/cluster"
    plugins="$(oc get console.operator cluster -o json | jq -c '(.spec.plugins // []) - ["pipelines-console-plugin"]')"
    oc patch console.operator cluster --type=merge -p "{\"spec\":{\"plugins\":${plugins}}}"
fi
oc delete subscription openshift-pipelines-operator-rh -n openshift-operators --ignore-not-found

log "==> Deleting zot (namespace ${ZOT_NAMESPACE})"
oc delete namespace "$ZOT_NAMESPACE" --ignore-not-found

rm -f infra-env.sh env.sh
log "done. Re-run install-infra.sh to recreate with fresh keys/routes."
