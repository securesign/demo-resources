#!/usr/bin/env bash
#
# Installs the long-lived infrastructure for the RHTAS signing demo on
# OpenShift. This is the slow, one-time, occasionally-disruptive part.
# Run it once per cluster, then replay the actual demo as many times as you
# want with ./run-demo.sh.
#
#   1. zot registry
#   2. Mirror rhtas-operator + policy-controller-operator (catalog, bundles,
#      and every operand image) into zot via oc-mirror. A cluster-wide IDMS
#      redirects registry.redhat.io/rhtas/* to the zot imges.
#      Pre-stage cosign, curl, and busybox into zot too, so later steps never
#      need public registry access to sign anything, fetch an OIDC token, or
#      build the unsigned/wrong-identity negative-scenario images.
#   3. Install rhtas-operator + policy-controller-operator from the
#      zot-hosted CatalogSource
#   4. Keycloak (OIDC issuer for keyless signing)
#   5. Securesign CR (Fulcio/Rekor/CTLog/Trillian/TUF/TSA)
#   6. OpenShift Pipelines operator + the reusable build-sign Pipeline,
#      demo namespace, and its ServiceAccount/Secret/ConfigMap. Also
#      registers the Pipelines console plugin so the Developer perspective
#      shows a Pipelines dashboard.
#
# WARNING: applying the ImageDigestMirrorSet in step 2 rolls every
# MachineConfigPool on the cluster (cordon, drain, reboot, one node at a
# time). Slow and disruptive. Never point this at a shared cluster
# without checking first!
#
# Usage:
#   oc login ...        # do this yourself first
#   ./install-infra.sh [--yes]
#   ./run-demo.sh        # then, as many times as you like
#
# Key env overrides (see common.sh for the rest):
#   ZOT_NAMESPACE            zot-tas-demo
#   TAS_OPERATOR_NAMESPACE   securesign-system   (rhtas-operator + policy-controller-operator Subscriptions)
#   POLICY_CONTROLLER_NAMESPACE   policy-controller-operator (fixed; see common.sh where the PolicyController CR must live)
#   TAS_NAMESPACE            rhtas-demo          (Securesign CR + operands)
#   DEMO_NAMESPACE           tas-demo            (pipeline + sample deployments)
#   KEYCLOAK_NAMESPACE       keycloak-system     (shared SSO instance across RHTAS demos on this cluster; override only for an isolated Keycloak)
#   COSIGN_VERSION           1.2.2               (TAS 1.2's supported cosign)
#   OC_MIRROR_EXTRA_ARGS     ""                  (add a TLS-skip flag here if your ingress cert isn't publicly trusted)
#
# Prerequisites:
#   - oc logged into the target cluster (OCP 4.21+)
#   - pull secret for registry.redhat.io available to oc-mirror
#   - oc-mirror v2 CLI plugin, skopeo, jq, envsubst, cosign on PATH
set -euo pipefail
cd "$(dirname "$0")"

[[ "${1:-}" == "--yes" ]] && ASSUME_YES=1
source ./common.sh

preflight() {
    require_bin oc
    require_bin jq
    require_bin envsubst
    require_bin skopeo
    require_bin cosign
    require_bin curl
    command -v oc-mirror >/dev/null 2>&1 || command -v "oc mirror" >/dev/null 2>&1 || \
        oc mirror --help >/dev/null 2>&1 || die "oc-mirror plugin not found (oc mirror --help failed)"
    oc whoami >/dev/null 2>&1 || die "not logged in (run 'oc login' first)"
    log "logged in to $(oc whoami --show-server) as $(oc whoami)"

    APPS_DOMAIN="$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
    [[ -n "$APPS_DOMAIN" ]] || die "could not read the cluster's apps domain"
    export APPS_DOMAIN
    log "apps domain: ${APPS_DOMAIN}"

    if [[ -z "$OCP_VERSION" ]]; then
        local full
        full="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)"
        [[ -n "$full" ]] || die "could not read clusterversion; set OCP_VERSION=<major>.<minor> manually (e.g. 4.21)"
        OCP_VERSION="$(cut -d. -f1,2 <<<"$full")"
        log "detected OpenShift ${full} -> ${OCP_VERSION}"
    fi
    export OCP_VERSION

    log "verifying cosign image ${COSIGN_SRC_IMAGE} is reachable (pre-stage source)"
    local skopeo_err
    if ! skopeo_err="$(skopeo inspect --raw "docker://${COSIGN_SRC_IMAGE}" 2>&1 >/dev/null)"; then
        die "cannot inspect ${COSIGN_SRC_IMAGE}: ${skopeo_err}
(registry.redhat.io requires an authenticated pull secret - a 401/403 here usually means your container auth file, e.g. ~/.docker/config.json or \$REGISTRY_AUTH_FILE, has no valid registry.redhat.io credentials. A timeout/connection error instead points at outbound network or proxy access to registry.redhat.io.)"
    fi

    log "verifying curl image ${CURL_SRC_IMAGE} is reachable (pre-stage source)"
    if ! skopeo_err="$(skopeo inspect --raw --no-creds "docker://${CURL_SRC_IMAGE}" 2>&1 >/dev/null)"; then
        die "cannot inspect ${CURL_SRC_IMAGE}: ${skopeo_err}
(a 401/429 here usually means Docker Hub's anonymous-pull rate limit. A timeout/connection error instead points at outbound network or proxy access to docker.io.)"
    fi

    log "verifying busybox image ${UNSIGNED_SRC_IMAGE} is reachable (pre-stage source)"
    if ! skopeo_err="$(skopeo inspect --raw --no-creds "docker://${UNSIGNED_SRC_IMAGE}" 2>&1 >/dev/null)"; then
        die "cannot inspect ${UNSIGNED_SRC_IMAGE}: ${skopeo_err}
(a 401/429 here usually means Docker Hub's anonymous-pull rate limit. A timeout/connection error instead points at outbound network or proxy access to docker.io.)"
    fi
}

# ---- Phase 1: zot ---------------------------------------------------------
install_zot() {
    log "==> Phase 1: installing zot"
    export ZOT_NAMESPACE
    envsubst '${ZOT_NAMESPACE},${APPS_DOMAIN}' < manifests/infra/zot.yaml | oc apply -f -
    wait_for_deployment_available "$ZOT_NAMESPACE" zot 5m

    ZOT_ROUTE="$(discover_ingress_host "$ZOT_NAMESPACE" zot)"
    [[ -n "$ZOT_ROUTE" ]] || die "could not find a zot route in namespace ${ZOT_NAMESPACE}"
    log "zot route: ${ZOT_ROUTE}"

    log "smoke-testing zot"
    curl -sf "https://${ZOT_ROUTE}/v2/" >/dev/null || die "zot at ${ZOT_ROUTE} did not respond to /v2/"
}

# Pre-stages cosign into zot so run-demo.sh's pipeline and
# wrong-identity signing step never need public registry access to get a
# signing binary.
prestage_cosign() {
    log "==> pre-staging cosign into zot"
    COSIGN_ZOT_IMAGE="${ZOT_ROUTE}/${COSIGN_ZOT_REPO}:${COSIGN_VERSION}"
    skopeo copy --all "docker://${COSIGN_SRC_IMAGE}" "docker://${COSIGN_ZOT_IMAGE}" $OC_MIRROR_EXTRA_ARGS
    log "cosign staged at ${COSIGN_ZOT_IMAGE}"
}

# Pre-stages curl into zot so the pipeline's get-oidc-token step never needs
# public registry access to reach docker.io.
prestage_curl() {
    log "==> pre-staging curl into zot"
    CURL_ZOT_IMAGE="${ZOT_ROUTE}/${CURL_ZOT_REPO}:${CURL_VERSION}"
    skopeo copy --all --src-no-creds "docker://${CURL_SRC_IMAGE}" "docker://${CURL_ZOT_IMAGE}" $OC_MIRROR_EXTRA_ARGS
    log "curl staged at ${CURL_ZOT_IMAGE}"
}

# Pre-stages busybox into zot so run-demo.sh's unsigned/wrong-identity
# negative scenarios never need public registry access at demo-run time.
# --src-no-creds avoids stale local credentials for what should
# be an anonymous pull.
prestage_busybox() {
    log "==> pre-staging busybox into zot"
    BUSYBOX_ZOT_IMAGE="${ZOT_ROUTE}/${BUSYBOX_ZOT_REPO}:latest"
    skopeo copy --override-os linux --override-arch amd64 --src-no-creds \
        "docker://${UNSIGNED_SRC_IMAGE}" "docker://${BUSYBOX_ZOT_IMAGE}" $OC_MIRROR_EXTRA_ARGS
    log "busybox staged at ${BUSYBOX_ZOT_IMAGE}"
}

# ---- Phase 2: mirror RHTAS + policy-controller-operator into zot ----------
mirror_tas_into_zot() {
    log "==> Phase 2: mirroring rhtas-operator + policy-controller-operator into zot"
    export RHTAS_OPERATOR_CHANNEL POLICY_CONTROLLER_CHANNEL
    envsubst '${OCP_VERSION},${RHTAS_OPERATOR_CHANNEL},${POLICY_CONTROLLER_CHANNEL}' \
        < manifests/infra/imageset-config.yaml > /tmp/tas-demo-imageset-config.yaml

    log "running oc-mirror (this downloads the full RHTAS + policy-controller-operator product set)"
    oc mirror --v2 --config /tmp/tas-demo-imageset-config.yaml --parallel-images 4 \
        --workspace "file://${OC_MIRROR_WORKSPACE_DIR}" "docker://${ZOT_ROUTE}" $OC_MIRROR_EXTRA_ARGS

    local results_dir="${OC_MIRROR_WORKSPACE_DIR}/working-dir/cluster-resources"
    [[ -d "$results_dir" ]] || die "oc-mirror did not produce a cluster-resources directory (${results_dir})"
    log "oc-mirror results: ${results_dir}"

    IDMS_FILE="$(ls "${results_dir}"/idms-*.yaml 2>/dev/null | head -1)"
    CATSRC_FILE="$(ls "${results_dir}"/cs-*.yaml 2>/dev/null | head -1)"
    [[ -n "$IDMS_FILE" ]] || die "no ImageDigestMirrorSet manifest found in ${results_dir}"
    [[ -n "$CATSRC_FILE" ]] || die "no CatalogSource manifest found in ${results_dir}"

    echo
    echo "About to apply an ImageDigestMirrorSet. This rolls EVERY MachineConfigPool"
    echo "on the cluster (cordon, drain, reboot, one node at a time). This is slow"
    echo "and disruptive to anyone else using this cluster."
    confirm "Apply ${IDMS_FILE} and roll all nodes on $(oc whoami --show-server)?" \
        || die "aborted before applying ImageDigestMirrorSet"

    oc apply -f "$IDMS_FILE"
    wait_for_mcp_rollout

    CATALOG_NAME="$(oc apply --dry-run=client -o json -f "$CATSRC_FILE" | jq -r '.metadata.name')"
    CATALOG_NAMESPACE="$(oc apply --dry-run=client -o json -f "$CATSRC_FILE" | jq -r '.metadata.namespace')"
    oc apply -f "$CATSRC_FILE"
    wait_for_catalog_source_ready "$CATALOG_NAME" "$CATALOG_NAMESPACE"
}

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
    die "MCP rollout did not complete within ${MCP_TIMEOUT}s"
}

# ---- Phase 3: install rhtas-operator + policy-controller-operator --------
install_tas_operators() {
    log "==> Phase 3: installing rhtas-operator + policy-controller-operator from ${CATALOG_NAME}"

    check_no_conflicting_subscription rhtas-operator
    check_no_conflicting_subscription policy-controller-operator

    oc create namespace "$TAS_OPERATOR_NAMESPACE" --dry-run=client -o yaml | oc apply -f -
    oc create namespace "$POLICY_CONTROLLER_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    if [[ -z "$(oc get operatorgroup -n "$TAS_OPERATOR_NAMESPACE" -o name 2>/dev/null)" ]]; then
        export TAS_OPERATOR_NAMESPACE
        envsubst '${TAS_OPERATOR_NAMESPACE}' < manifests/infra/operator-group.yaml | oc apply -f -
    fi

    create_subscription rhtas-operator "$RHTAS_OPERATOR_CHANNEL"
    create_subscription policy-controller-operator "$POLICY_CONTROLLER_CHANNEL"

    wait_for_crd securesigns.rhtas.redhat.com
    wait_for_crd clusterimagepolicies.policy.sigstore.dev

    wait_for_csv_succeeded rhtas-operator
    wait_for_csv_succeeded policy-controller-operator

    if ! oc get policycontroller policycontroller-sample -n "$POLICY_CONTROLLER_NAMESPACE" >/dev/null 2>&1; then
        export POLICY_CONTROLLER_NAMESPACE
        envsubst '${POLICY_CONTROLLER_NAMESPACE}' < manifests/infra/policy-controller.yaml | oc apply -f -
    fi

    log "waiting for the PolicyController CR to deploy its admission webhook"
    local waited=0
    until [[ -n "$(oc get validatingwebhookconfigurations -o name 2>/dev/null | grep -i validating.clusterimagepolicy.rhtas.com || true)" ]]; do
        (( waited >= 300 )) && die "PolicyController CR did not deploy a validating webhook within 300s, check 'oc logs -n ${TAS_OPERATOR_NAMESPACE} -l control-plane=controller-manager'"
        sleep 10; waited=$((waited + 10))
    done

    log "waiting for the ClusterImagePolicy conversion webhook's service"
    wait_for_deployment_available "$POLICY_CONTROLLER_NAMESPACE" policycontroller-sample-policy-controller-webhook 5m

    log "waiting for the ClusterImagePolicy CRD's conversion webhook clientConfig to settle"
    wait_for_cip_conversion_ready "$POLICY_CONTROLLER_NAMESPACE"
}

# Both packages only support the AllNamespaces install mode, so a second
# Subscription to the same package in a different namespace competes with an
# existing one cluster-wide instead of coexisting. Warn loudly rather than
# create a conflicting install.
check_no_conflicting_subscription() {
    local package="$1" existing
    existing="$(oc get subscriptions -A -o json \
        | jq -r --arg pkg "$package" --arg ns "$TAS_OPERATOR_NAMESPACE" \
            '.items[] | select(.spec.name == $pkg and .metadata.namespace != $ns) | .metadata.namespace')"
    if [[ -n "$existing" ]]; then
        echo
        echo "A Subscription for ${package} already exists in namespace(s): ${existing}"
        echo "Installing another one in ${TAS_OPERATOR_NAMESPACE} will likely conflict (AllNamespaces-scoped operators can't coexist from two Subscriptions)."
        confirm "Continue anyway?" || die "aborted: resolve the existing ${package} Subscription first (reuse it, or remove it)"
    fi
}

create_subscription() {
    local package="$1" channel="$2"
    log "creating Subscription/${package} in ${TAS_OPERATOR_NAMESPACE} (channel ${channel})"
    export SUBSCRIPTION_PACKAGE="$package" SUBSCRIPTION_CHANNEL="$channel" TAS_OPERATOR_NAMESPACE CATALOG_NAME CATALOG_NAMESPACE
    envsubst '${SUBSCRIPTION_PACKAGE},${SUBSCRIPTION_CHANNEL},${TAS_OPERATOR_NAMESPACE},${CATALOG_NAME},${CATALOG_NAMESPACE}' \
        < manifests/infra/operator-subscription.yaml | oc apply -f -
}

# ---- Phase 4: Keycloak -----------------------------------------------------
install_keycloak() {
    log "==> Phase 4: installing Keycloak"
    export KEYCLOAK_NAMESPACE
    envsubst '${KEYCLOAK_NAMESPACE}' < manifests/infra/keycloak-operator.yaml | oc apply -f -
    wait_for_crd keycloaks.keycloak.org

    export SIGNER_USERNAME SIGNER_EMAIL SIGNER_PASSWORD SIGNER_FIRST_NAME SIGNER_LAST_NAME
    export WRONG_IDENTITY_USERNAME WRONG_IDENTITY_EMAIL WRONG_IDENTITY_PASSWORD
    envsubst < manifests/infra/keycloak-resources.yaml | oc apply -f -

    log "waiting for Keycloak to be ready"
    wait_for_keycloak_ready "$KEYCLOAK_NAMESPACE" keycloak 600

    KEYCLOAK_ROUTE="$(discover_route "$KEYCLOAK_NAMESPACE" keycloak)"
    [[ -n "$KEYCLOAK_ROUTE" ]] || die "could not find the keycloak route in ${KEYCLOAK_NAMESPACE}"
    KEYCLOAK_ISSUER="https://${KEYCLOAK_ROUTE}/auth/realms/trusted-artifact-signer"
    KEYCLOAK_TOKEN_URL="${KEYCLOAK_ISSUER}/protocol/openid-connect/token"
    log "keycloak issuer: ${KEYCLOAK_ISSUER}"
}

# ---- Phase 5: Securesign ----------------------------------------------------
install_securesign() {
    log "==> Phase 5: installing Securesign"
    export TAS_NAMESPACE KEYCLOAK_NAMESPACE
    envsubst '${APPS_DOMAIN},${TAS_NAMESPACE},${KEYCLOAK_NAMESPACE}' < manifests/infra/securesign.yaml | oc apply -f -

    log "waiting for Securesign to be Ready (this can take several minutes)"
    oc wait --for=condition=Ready "securesign/trusted-artifact-signer" -n "$TAS_NAMESPACE" --timeout=10m

    TUF_ROUTE="$(discover_ingress_host "$TAS_NAMESPACE" tuf)"
    FULCIO_ROUTE="$(discover_ingress_host "$TAS_NAMESPACE" fulcio-server)"
    REKOR_ROUTE="$(discover_ingress_host "$TAS_NAMESPACE" rekor-server)"
    for pair in "TUF_ROUTE:$TUF_ROUTE" "FULCIO_ROUTE:$FULCIO_ROUTE" "REKOR_ROUTE:$REKOR_ROUTE"; do
        [[ -n "${pair#*:}" ]] || die "could not discover ${pair%%:*}, check 'oc get ingress -n ${TAS_NAMESPACE}' and adjust discover_ingress_host names"
    done
    CTLOG_ROUTE="ctlog.${TAS_NAMESPACE}.svc.cluster.local:443"
    log "tuf=${TUF_ROUTE} fulcio=${FULCIO_ROUTE} rekor=${REKOR_ROUTE} ctlog=${CTLOG_ROUTE} (ctlog is cluster-internal, no public route)"

    TSA_URL="$(oc get timestampauthority -n "$TAS_NAMESPACE" -o jsonpath='{.items[0].status.url}')"
    [[ -n "$TSA_URL" ]] || die "could not discover TSA_URL, check 'oc get timestampauthority -n ${TAS_NAMESPACE}'"
    TSA_URL="${TSA_URL}/api/v1/timestamp"
    log "tsa=${TSA_URL}"

    TUF_MIRROR_URL="https://${TUF_ROUTE}"
    TUF_ROOT_URL="https://${TUF_ROUTE}/root.json"

    log "initializing local cosign trust store"
    cosign initialize --mirror "$TUF_MIRROR_URL" --root "$TUF_ROOT_URL"
}

# ---- Phase 6: OpenShift Pipelines + demo namespace plumbing -----------------
install_pipelines() {
    log "==> Phase 6: installing OpenShift Pipelines"
    oc apply -f manifests/infra/pipelines-operator.yaml
    wait_for_crd pipelines.tekton.dev
    wait_for_crd pipelineruns.tekton.dev

    log "waiting for the Tekton Pipelines webhook to be available"
    wait_for_deployment_available openshift-pipelines tekton-pipelines-webhook 5m

    enable_pipelines_console_plugin

    oc create namespace "$DEMO_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    log "waiting for the default 'pipeline' ServiceAccount to be provisioned in ${DEMO_NAMESPACE}"
    local waited=0
    until oc get serviceaccount pipeline -n "$DEMO_NAMESPACE" >/dev/null 2>&1; do
        (( waited >= 120 )) && die "ServiceAccount/pipeline never appeared in ${DEMO_NAMESPACE}"
        sleep 5; waited=$((waited + 5))
    done

    oc adm policy add-scc-to-user privileged -z pipeline -n "$DEMO_NAMESPACE"

    oc create secret generic signer-credentials \
        --from-literal=username="$SIGNER_USERNAME" \
        --from-literal=password="$SIGNER_PASSWORD" \
        -n "$DEMO_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    oc create configmap sample-app-source \
        --from-file=Containerfile=sample-app/Containerfile \
        -n "$DEMO_NAMESPACE" --dry-run=client -o yaml | oc apply -f -

    export DEMO_NAMESPACE
    envsubst '${DEMO_NAMESPACE}' < manifests/demo/build-sign-pipeline.yaml | oc apply -f -
}

enable_pipelines_console_plugin() {
    log "enabling the OpenShift Pipelines console plugin"
    wait_for_deployment_available openshift-pipelines pipelines-console-plugin 5m

    if oc get console.operator cluster -o jsonpath='{.spec.plugins}' | grep -q pipelines-console-plugin; then
        log "pipelines-console-plugin already registered with the console"
        return
    fi

    local plugins
    plugins="$(oc get console.operator cluster -o json | jq -c '(.spec.plugins // []) + ["pipelines-console-plugin"] | unique')"
    oc patch console.operator cluster --type=merge -p "{\"spec\":{\"plugins\":${plugins}}}"
    log "registered pipelines-console-plugin; console pods will roll (~1m) to pick it up"
}

# ---- infra-env.sh -----------------------------------------------------------
write_infra_env_file() {
    log "writing infra-env.sh"
    cat > infra-env.sh <<EOF
export ZOT_NAMESPACE="${ZOT_NAMESPACE}"
export ZOT_ROUTE="${ZOT_ROUTE}"
export TAS_NAMESPACE="${TAS_NAMESPACE}"
export DEMO_NAMESPACE="${DEMO_NAMESPACE}"
export TUF_ROUTE="${TUF_ROUTE}"
export FULCIO_ROUTE="${FULCIO_ROUTE}"
export REKOR_ROUTE="${REKOR_ROUTE}"
export CTLOG_ROUTE="${CTLOG_ROUTE}"
export TSA_URL="${TSA_URL}"
export TUF_MIRROR_URL="${TUF_MIRROR_URL}"
export TUF_ROOT_URL="${TUF_ROOT_URL}"
export KEYCLOAK_ROUTE="${KEYCLOAK_ROUTE}"
export KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER}"
export KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL}"
export COSIGN_ZOT_IMAGE="${COSIGN_ZOT_IMAGE}"
export CURL_ZOT_IMAGE="${CURL_ZOT_IMAGE}"
export BUSYBOX_ZOT_IMAGE="${BUSYBOX_ZOT_IMAGE}"
EOF
    log "wrote infra-env.sh"
}

# ---- Main ---------------------------------------------------------------
preflight
install_zot
prestage_cosign
prestage_curl
prestage_busybox
mirror_tas_into_zot
install_tas_operators
install_keycloak
install_securesign
install_pipelines
write_infra_env_file

log "infra ready. Run ./run-demo.sh (as many times as you like) to build, sign,"
log "and gate a deployment."
