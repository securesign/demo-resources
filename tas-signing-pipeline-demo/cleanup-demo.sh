#!/usr/bin/env bash
#
# Tears down what run-demo.sh created: the ClusterImagePolicy, the
# TrustRoot, the PipelineRuns, and the three demo Deployments
# (signed/unsigned/wrong-identity app).
#
# Usage:
#   ./cleanup-demo.sh [--yes]
set -euo pipefail
cd "$(dirname "$0")"

[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1
source ./common.sh

oc whoami >/dev/null 2>&1 || die "not logged in (run 'oc login' first)"
log "logged in to $(oc whoami --show-server) as $(oc whoami)"

log "==> Deleting ClusterImagePolicy and TrustRoot"
if oc get crd clusterimagepolicies.policy.sigstore.dev >/dev/null 2>&1; then
    oc delete clusterimagepolicies.policy.sigstore.dev tas-demo-policy --ignore-not-found
fi
if oc get crd trustroots.policy.sigstore.dev >/dev/null 2>&1; then
    oc delete trustroots.policy.sigstore.dev tas-demo-trust-root --ignore-not-found
fi

if ns_exists "$DEMO_NAMESPACE"; then
    log "==> Deleting demo deployments and pipeline runs in ${DEMO_NAMESPACE}"
    oc delete deployment signed-app unsigned-app wrong-identity-app -n "$DEMO_NAMESPACE" --ignore-not-found
    oc delete pipelinerun -l tekton.dev/pipeline=build-sign -n "$DEMO_NAMESPACE" --ignore-not-found

    log "==> Removing policy-controller admission label from ${DEMO_NAMESPACE}"
    oc label namespace "$DEMO_NAMESPACE" "${POLICY_NAMESPACE_LABEL%%=*}-" >/dev/null 2>&1 || true
else
    log "namespace ${DEMO_NAMESPACE} does not exist"
fi

log "done. Re-run run-demo.sh to rebuild fresh signed/unsigned/wrong-identity images and deployments."
