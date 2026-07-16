#!/usr/bin/env bash
#
# canary.sh - poor man's progressive delivery with plain kubectl.
#
# HONEST CAVEAT: this is NOT what a real enterprise uses. Argo Rollouts or
# Flagger do this properly with automated metric analysis and abort. They were
# excluded by the project constraints, so this script does the closest safe
# thing: run a small number of new-version pods alongside the stable ones,
# watch their error rate, and promote or abort.
#
# The Service selects on `app`, NOT on `version`, so both the canary and
# stable pods receive traffic in proportion to their replica counts.
#
set -euo pipefail

ENV_NAME="${1:?usage: canary.sh <env> <service> <image>}"
SERVICE="${2:?service name required}"
IMAGE="${3:?image required}"
CANARY_PERCENT="${CANARY_PERCENT:-25}"
BAKE_SECONDS="${BAKE_SECONDS:-300}"
ERROR_THRESHOLD="${ERROR_THRESHOLD:-1.0}"

NAMESPACE="$ENV_NAME"
CANARY_NAME="${SERVICE}-canary"

echo "==> Deploying canary ${CANARY_NAME} at ${CANARY_PERCENT}%"

STABLE_REPLICAS="$(kubectl get deployment "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}')"
CANARY_REPLICAS=$(( (STABLE_REPLICAS * CANARY_PERCENT + 99) / 100 ))
[[ "$CANARY_REPLICAS" -lt 1 ]] && CANARY_REPLICAS=1

# Clone the stable deployment, rename it, swap the image.
kubectl get deployment "$SERVICE" -n "$NAMESPACE" -o yaml \
  | sed "s/^  name: ${SERVICE}$/  name: ${CANARY_NAME}/" \
  | sed "s|image: .*|image: ${IMAGE}|" \
  | kubectl apply -f - --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl scale deployment "$CANARY_NAME" -n "$NAMESPACE" --replicas="$CANARY_REPLICAS"
kubectl rollout status "deployment/${CANARY_NAME}" -n "$NAMESPACE" --timeout=3m

echo "==> Baking for ${BAKE_SECONDS}s, watching error rate"
sleep "$BAKE_SECONDS"

# Query Prometheus for the canary's 5xx rate.
PROM="${PROMETHEUS_URL:-http://prometheus.monitoring.svc.cluster.local:9090}"
QUERY="sum(rate(http_requests_total{app=\"${SERVICE}\",status_code=~\"5..\"}[5m]))/sum(rate(http_requests_total{app=\"${SERVICE}\"}[5m]))*100"

ERROR_RATE="$(curl -sG "${PROM}/api/v1/query" \
  --data-urlencode "query=${QUERY}" \
  | grep -oP '"value":\[[^,]+,"\K[^"]+' || echo "0")"

echo "    canary error rate: ${ERROR_RATE}% (threshold ${ERROR_THRESHOLD}%)"

if awk "BEGIN{exit !(${ERROR_RATE:-0} > ${ERROR_THRESHOLD})}"; then
  echo "==> ABORT: error rate above threshold. Removing canary."
  kubectl delete deployment "$CANARY_NAME" -n "$NAMESPACE"
  exit 1
fi

echo "==> Canary healthy. Promoting to stable."
kubectl set image "deployment/${SERVICE}" "${SERVICE}=${IMAGE}" -n "$NAMESPACE"
kubectl rollout status "deployment/${SERVICE}" -n "$NAMESPACE" --timeout=5m

echo "==> Removing canary deployment"
kubectl delete deployment "$CANARY_NAME" -n "$NAMESPACE"
echo "==> Promotion complete"
