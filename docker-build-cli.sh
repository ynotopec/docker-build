#!/usr/bin/env bash
# docker-build-cli.sh — use the Docker Build Factory without MCP.
#
# Pure-bash, kubectl-only client for the K8s Docker-in-Docker build pod and the
# internal registry. Mirrors the seven MCP tools so any AI agent (or a human)
# can drive the factory from a shell, with no config file and no restart.
#
# Usage:
#   ./docker-build-cli.sh build   IMAGE_NAME [CONTEXT_DIR]   # build from a Dockerfile
#   ./docker-build-cli.sh push    IMAGE_NAME                 # push to registry:5000
#   ./docker-build-cli.sh pull    IMAGE_NAME                 # pull from registry:5000
#   ./docker-build-cli.sh run     IMAGE_NAME [COMMAND...]    # run a container once
#   ./docker-build-cli.sh images                             # list local images in the pod
#   ./docker-build-cli.sh registry                           # list images in the registry
#   ./docker-build-cli.sh cleanup                            # prune unused docker data
#
# Environment:
#   KUBE_NAMESPACE   required, no implicit default
#   KUBECTL          optional, path to the kubectl binary
#   KUBECONFIG       optional, honoured by kubectl itself
#   BUILD_POD        optional, pod name (default: docker-build)
#   REGISTRY_URL     optional, registry host (default: registry:5000)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env from the repo root so the namespace/token survive across shells.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

NS="${KUBE_NAMESPACE:?KUBE_NAMESPACE must be set in .env or the environment}"
POD="${BUILD_POD:-docker-build}"
REGISTRY="${REGISTRY_URL:-registry:5000}"

# Resolve kubectl: explicit override, then PATH, then the usual user-local dirs.
resolve_kubectl() {
    if [[ -n "${KUBECTL:-}" ]]; then printf '%s\n' "$KUBECTL"; return; fi
    local found
    if found="$(command -v kubectl 2>/dev/null)"; then printf '%s\n' "$found"; return; fi
    for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin /usr/bin /workspace; do
        if [[ -x "$d/kubectl" ]]; then printf '%s\n' "$d/kubectl"; return; fi
    done
    echo "kubectl not found; set KUBECTL or put it on PATH" >&2
    exit 127
}
KUBECTL_BIN="$(resolve_kubectl)"

k() { "$KUBECTL_BIN" -n "$NS" "$@"; }

# Wait until the build pod exists and its Docker daemon answers.
ensure_pod() {
    if ! k get pod "$POD" &>/dev/null; then
        echo "[✗] Pod $POD not found in namespace $NS." >&2
        echo "    Deploy it first: KUBE_NAMESPACE=$NS TLS_HOST=... CERT_MANAGER_CLUSTER_ISSUER=... ./docker-build-setup.sh" >&2
        exit 1
    fi
    k wait pod/"$POD" --for=condition=ready --timeout=120s >/dev/null
}

cmd_build() {
    local image="${1:?build requires IMAGE_NAME}"
    local context="${2:-.}"
    if [[ ! -f "$context/Dockerfile" ]]; then
        echo "[✗] No Dockerfile found in $context" >&2
        exit 1
    fi
    ensure_pod
    local dir
    dir="$(k exec "$POD" -- mktemp -d /tmp/agent-build.XXXXXX)"
    trap 'k exec "$POD" -- rm -rf -- "$dir" >/dev/null 2>&1 || true' RETURN
    echo "[→] Copying build context ($context) to pod $POD..."
    tar -C "$context" -cf - . | k exec -i "$POD" -- tar -C "$dir" -xf -
    echo "[→] Building $image..."
    k exec "$POD" -- docker build -t "$image" "$dir"
    echo "[✓] Built $image"
}

cmd_push() {
    local image="${1:?push requires IMAGE_NAME}"
    ensure_pod
    local tagged="$REGISTRY/$image"
    echo "[→] Tagging $image -> $tagged"
    k exec "$POD" -- docker tag "$image" "$tagged"
    echo "[→] Pushing $tagged..."
    k exec "$POD" -- docker push "$tagged"
    echo "[✓] Pushed $tagged"
}

cmd_pull() {
    local image="${1:?pull requires IMAGE_NAME}"
    ensure_pod
    echo "[→] Pulling $REGISTRY/$image..."
    k exec "$POD" -- docker pull "$REGISTRY/$image"
    echo "[✓] Pulled $REGISTRY/$image"
}

cmd_run() {
    local image="${1:?run requires IMAGE_NAME}"
    shift || true
    ensure_pod
    local args=(--rm "$image")
    (($#)) && args+=("$@")
    echo "[→] Running $image..."
    k exec "$POD" -- docker run "${args[@]}"
}

cmd_images() {
    ensure_pod
    echo "=== Local images in pod $POD ==="
    k exec "$POD" -- docker images
}

cmd_registry() {
    ensure_pod
    echo "=== Images in registry ($REGISTRY) ==="
    k exec "$POD" -- sh -c "wget -qO- http://$REGISTRY/v2/_catalog 2>/dev/null || curl -s http://$REGISTRY/v2/_catalog"
    echo
}

cmd_cleanup() {
    ensure_pod
    echo "[→] Pruning unused Docker data in pod $POD..."
    k exec "$POD" -- docker system prune -f
    echo "[✓] Done"
}

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    build)    shift; cmd_build "$@" ;;
    push)     shift; cmd_push "$@" ;;
    pull)     shift; cmd_pull "$@" ;;
    run)      shift; cmd_run "$@" ;;
    images)   cmd_images ;;
    registry) cmd_registry ;;
    cleanup)  cmd_cleanup ;;
    ""|-h|--help|help) usage ;;
    *) echo "Unknown command: $1" >&2; echo; usage >&2; exit 2 ;;
esac
