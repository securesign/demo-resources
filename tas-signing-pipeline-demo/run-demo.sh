#!/usr/bin/env bash
#
# Runs the replayable part of the RHTAS signing demo: build + sign an image,
# then gate deployments on it (positive and negative scenarios). Safe to run
# repeatedly against infra already installed by ./install-infra.sh.
# Each run creates a fresh PipelineRun and re-applies the demo Deployments
# and ClusterImagePolicy in place.
#
#   7. Tekton pipeline: buildah build -> push to zot -> cosign 2.x sign
#      against the local Fulcio/Rekor/TSA, RFC3161-timestamped
#   8. ClusterImagePolicy + three deployments: signed (passes), unsigned
#      (blocked), wrong-identity (blocked)
#   9. env.sh with every discovered route and identity
#
# Usage:
#   ./install-infra.sh   # once per cluster
#   ./run-demo.sh [--yes]
set -euo pipefail
cd "$(dirname "$0")"

[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1
source ./common.sh

[[ -f infra-env.sh ]] || die "infra-env.sh not found, run ./install-infra.sh first"
source ./infra-env.sh

require_bin oc
require_bin jq
require_bin envsubst
require_bin skopeo
require_bin cosign
require_bin curl
oc whoami >/dev/null 2>&1 || die "not logged in (run 'oc login' first)"
log "logged in to $(oc whoami --show-server) as $(oc whoami)"

# ---- Phase 7: build, push, sign ---------------------------------------------
run_build_sign_pipeline() {
    section "==> Phase 7: running the build-sign pipeline"

    local policy_label_key="${POLICY_NAMESPACE_LABEL%%=*}"
    oc label namespace "$DEMO_NAMESPACE" "${policy_label_key}-" --overwrite >/dev/null 2>&1 || true

    SAMPLE_IMAGE_REF="${ZOT_ROUTE}/${SAMPLE_APP_REPO}:${SAMPLE_APP_TAG}"

    export DEMO_NAMESPACE SAMPLE_IMAGE_REF KEYCLOAK_TOKEN_URL OIDC_CLIENT_ID \
        TUF_MIRROR_URL TUF_ROOT_URL FULCIO_ROUTE REKOR_ROUTE TSA_URL COSIGN_ZOT_IMAGE CURL_ZOT_IMAGE
    local run_manifest
    run_manifest="$(envsubst < manifests/demo/pipeline-run.yaml)"
    PIPELINE_RUN_NAME="$(echo "$run_manifest" | oc create -f - -o jsonpath='{.metadata.name}')"
    log "started PipelineRun/${PIPELINE_RUN_NAME}"

    oc wait --for=condition=Succeeded "pipelinerun/${PIPELINE_RUN_NAME}" -n "$DEMO_NAMESPACE" --timeout=10m || {
        oc get pipelinerun "$PIPELINE_RUN_NAME" -n "$DEMO_NAMESPACE" -o yaml >&2
        die "PipelineRun/${PIPELINE_RUN_NAME} did not succeed, see output above"
    }

    SIGNED_IMAGE="$(oc get pipelinerun "$PIPELINE_RUN_NAME" -n "$DEMO_NAMESPACE" -o jsonpath='{.status.results[?(@.name=="signed-image")].value}')"
    [[ -n "$SIGNED_IMAGE" ]] || die "PipelineRun succeeded but did not publish a signed-image result"
    log "signed image: ${SIGNED_IMAGE}"

    log "verifying the signature locally"
    cosign verify --certificate-identity="$SIGNER_EMAIL" --certificate-oidc-issuer="$KEYCLOAK_ISSUER" "$SIGNED_IMAGE" \
        || die "cosign verify failed against the image the pipeline just signed"
}

# ---- Phase 8: policy gating --------------------------------------------------
verify_policy_namespace_label() {
    local policy_label_key="${POLICY_NAMESPACE_LABEL%%=*}" policy_label_value="${POLICY_NAMESPACE_LABEL#*=}"

    local selector
    selector="$(oc get validatingwebhookconfigurations -o json \
        | jq -r '[.items[].webhooks[]? | select([.rules[]?.resources[]?] | index("pods"))] | .[0].namespaceSelector // empty')"
    [[ -n "$selector" && "$selector" != "null" ]] \
        || die "could not find the policy-controller pod-admission ValidatingWebhookConfiguration to confirm the namespace opt-in label, inspect 'oc get validatingwebhookconfigurations' manually"

    echo "$selector" | jq -e --arg key "$policy_label_key" --arg val "$policy_label_value" \
        '.matchExpressions[]? | select(.key == $key and .operator == "In") | .values[]? | select(. == $val)' >/dev/null \
        || die "policy-controller webhook namespaceSelector does not require ${POLICY_NAMESPACE_LABEL} (selector: $(echo "$selector" | jq -c .)), namespace gating is not wired the way the demo expects"

    log "confirmed: policy-controller pod-admission webhook namespaceSelector requires ${POLICY_NAMESPACE_LABEL}"
}

setup_policy_gating() {
    section "==> Phase 8: policy gating (positive + negative scenarios)"

    CIP_API_VERSION="v1beta1"
    [[ "$(oc get crd clusterimagepolicies.policy.sigstore.dev -o jsonpath='{.spec.versions[?(@.name=="v1beta1")].served}')" == "true" ]] \
        || die "clusterimagepolicies.policy.sigstore.dev CRD does not serve v1beta1, please run ./install-infra.sh first"
    log "ClusterImagePolicy apiVersion: policy.sigstore.dev/${CIP_API_VERSION}"

    TRUST_ROOT_NAME="tas-demo-trust-root"
    TUF_ROOT_JSON_B64="$(curl -sfk "$TUF_ROOT_URL" | base64 | tr -d '\n')"
    [[ -n "$TUF_ROOT_JSON_B64" ]] || die "failed to fetch TUF root.json from ${TUF_ROOT_URL}"

    export TRUST_ROOT_NAME TUF_MIRROR_URL TUF_ROOT_JSON_B64
    envsubst '${TRUST_ROOT_NAME},${TUF_MIRROR_URL},${TUF_ROOT_JSON_B64}' < manifests/demo/trust-root.yaml | oc apply -f -
    oc wait --for=condition=Ready "trustroot.policy.sigstore.dev/${TRUST_ROOT_NAME}" --timeout=60s \
        || die "TrustRoot/${TRUST_ROOT_NAME} did not become Ready, see 'oc get trustroot.policy.sigstore.dev ${TRUST_ROOT_NAME} -o yaml'"

    export ZOT_ROUTE FULCIO_ROUTE REKOR_ROUTE TRUST_ROOT_NAME KEYCLOAK_ISSUER SIGNER_EMAIL CIP_API_VERSION
    envsubst < manifests/demo/cluster-image-policy.yaml | oc apply -f -

    log "waiting for the policy-controller admission webhook to be ready"
    local waited=0
    until [[ -n "$(oc get validatingwebhookconfigurations -o name 2>/dev/null | grep -i policy || true)" ]]; do
        (( waited >= 300 )) && die "no policy-controller ValidatingWebhookConfiguration appeared within 300s"
        sleep 10; waited=$((waited + 10))
    done

    log "pushing an unsigned image into zot"
    local unsigned_tag="${ZOT_ROUTE}/${UNSIGNED_APP_REPO}:latest" unsigned_digest
    skopeo copy --override-os linux --override-arch amd64 "docker://${BUSYBOX_ZOT_IMAGE}" "docker://${unsigned_tag}" $OC_MIRROR_EXTRA_ARGS
    unsigned_digest="$(skopeo inspect "docker://${unsigned_tag}" | jq -r '.Digest')"
    UNSIGNED_IMAGE="${ZOT_ROUTE}/${UNSIGNED_APP_REPO}@${unsigned_digest}"

    log "pushing + signing an image with the WRONG identity (${WRONG_IDENTITY_EMAIL})"
    local wrong_identity_tag="${ZOT_ROUTE}/${WRONG_IDENTITY_APP_REPO}:latest" wrong_identity_digest
    skopeo copy --override-os linux --override-arch amd64 "docker://${BUSYBOX_ZOT_IMAGE}" "docker://${wrong_identity_tag}" $OC_MIRROR_EXTRA_ARGS
    wrong_identity_digest="$(skopeo inspect "docker://${wrong_identity_tag}" | jq -r '.Digest')"
    WRONG_IDENTITY_IMAGE="${ZOT_ROUTE}/${WRONG_IDENTITY_APP_REPO}@${wrong_identity_digest}"

    export DEMO_NAMESPACE KEYCLOAK_TOKEN_URL OIDC_CLIENT_ID WRONG_IDENTITY_IMAGE \
        WRONG_IDENTITY_USERNAME WRONG_IDENTITY_PASSWORD TUF_MIRROR_URL TUF_ROOT_URL \
        TSA_URL COSIGN_ZOT_IMAGE CURL_ZOT_IMAGE
    envsubst '${DEMO_NAMESPACE}' < manifests/demo/sign-image-task.yaml | oc apply -f -
    local sign_taskrun_name
    sign_taskrun_name="$(envsubst < manifests/demo/sign-image-taskrun.yaml | oc create -f - -o jsonpath='{.metadata.name}')"
    log "started TaskRun/${sign_taskrun_name} (signing ${WRONG_IDENTITY_IMAGE} as ${WRONG_IDENTITY_EMAIL})"
    oc wait --for=condition=Succeeded "taskrun/${sign_taskrun_name}" -n "$DEMO_NAMESPACE" --timeout=5m || {
        oc get taskrun "$sign_taskrun_name" -n "$DEMO_NAMESPACE" -o yaml >&2
        die "TaskRun/${sign_taskrun_name} did not succeed, see output above"
    }

    export DEMO_NAMESPACE SIGNED_IMAGE UNSIGNED_IMAGE WRONG_IDENTITY_IMAGE

    oc label namespace "$DEMO_NAMESPACE" "$POLICY_NAMESPACE_LABEL" --overwrite
    verify_policy_namespace_label

    section "-- positive scenario: deploying the signed image (expect admission PASS) --"
    envsubst < manifests/demo/deploy-signed.yaml | oc apply -f -
    oc rollout status "deployment/signed-app" -n "$DEMO_NAMESPACE" --timeout=120s \
        || die "signed-app did not roll out, admission should have passed this image"

    section "-- negative scenario 1: deploying an unsigned image (expect admission BLOCK) --"
    if envsubst < manifests/demo/deploy-unsigned.yaml | oc apply -f - 2>/tmp/tas-demo-unsigned-reject.txt; then
        die "deploy-unsigned.yaml was admitted, expected the policy controller to block it. See ${DEMO_NAMESPACE}/unsigned-app."
    fi
    log "blocked as expected:"
    cat /tmp/tas-demo-unsigned-reject.txt >&2

    section "-- negative scenario 2: deploying a wrong-identity-signed image (expect admission BLOCK) --"
    if envsubst < manifests/demo/deploy-wrong-identity.yaml | oc apply -f - 2>/tmp/tas-demo-wrong-identity-reject.txt; then
        die "deploy-wrong-identity.yaml was admitted, expected the policy controller to block it."
    fi
    log "blocked as expected:"
    cat /tmp/tas-demo-wrong-identity-reject.txt >&2
}

# ---- Phase 9: env.sh ---------------------------------------------------------
write_env_file() {
    section "==> Phase 9: writing env.sh"
    cat > env.sh <<EOF
export ZOT_NAMESPACE="${ZOT_NAMESPACE}"
export ZOT_ROUTE="${ZOT_ROUTE}"
export TAS_NAMESPACE="${TAS_NAMESPACE}"
export DEMO_NAMESPACE="${DEMO_NAMESPACE}"
export TUF_ROUTE="${TUF_ROUTE}"
export FULCIO_ROUTE="${FULCIO_ROUTE}"
export REKOR_ROUTE="${REKOR_ROUTE}"
export CTLOG_ROUTE="${CTLOG_ROUTE}"
export TSA_URL="${TSA_URL}"
export KEYCLOAK_ROUTE="${KEYCLOAK_ROUTE}"
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER}"
export KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL}"
export SIGNER_IDENTITY="${SIGNER_EMAIL}"
export SIGNED_IMAGE="${SIGNED_IMAGE}"
export UNSIGNED_IMAGE="${UNSIGNED_IMAGE}"
export WRONG_IDENTITY_IMAGE="${WRONG_IDENTITY_IMAGE}"
export COSIGN_ZOT_IMAGE="${COSIGN_ZOT_IMAGE}"
export CURL_ZOT_IMAGE="${CURL_ZOT_IMAGE}"
export BUSYBOX_ZOT_IMAGE="${BUSYBOX_ZOT_IMAGE}"
EOF
    log "wrote env.sh"
}

# ---- Main ---------------------------------------------------------------
run_build_sign_pipeline
setup_policy_gating
write_env_file

section "done. Source env.sh and see the RHTAS/Fulcio/Rekor/TUF/Keycloak routes,"
log "the signed/unsigned/wrong-identity image refs, for the demo."
