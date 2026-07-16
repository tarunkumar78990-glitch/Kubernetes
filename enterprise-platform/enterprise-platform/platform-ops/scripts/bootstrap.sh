#!/usr/bin/env bash
#
# bootstrap.sh - lay the platform foundations, in the order that matters.
#
# Order is not cosmetic:
#   1. namespaces      - everything else lives in them
#   2. quotas          - before workloads, or dev can starve prod
#   3. default-deny    - BEFORE services, or you retro-fit security later
#   4. monitoring      - before services, so you see the first deploy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> 1/5 Namespaces"
kubectl apply -f "$OPS_ROOT/namespaces/namespaces.yaml"

echo "==> 2/5 Resource quotas and limit ranges"
kubectl apply -f "$OPS_ROOT/quotas/resourcequotas.yaml"

echo "==> 3/5 Default-deny NetworkPolicies"
echo "    Applying default-deny BEFORE workloads exist. Doing this after"
echo "    means a window where everything can reach everything."
kubectl apply -f "$OPS_ROOT/networkpolicies/default-deny.yaml"

echo "==> 4/5 Monitoring stack"
kubectl apply -f "$OPS_ROOT/monitoring/prometheus-rbac.yaml"
kubectl apply -f "$OPS_ROOT/monitoring/prometheus-config.yaml"

# Load the SLO rules as a ConfigMap Prometheus mounts.
kubectl create configmap prometheus-rules \
  --namespace monitoring \
  --from-file="$OPS_ROOT/slo/recording-rules.yaml" \
  --from-file="$OPS_ROOT/slo/burn-rate-alerts.yaml" \
  --from-file="$OPS_ROOT/slo/infrastructure-alerts.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$OPS_ROOT/monitoring/prometheus-deployment.yaml"
kubectl apply -f "$OPS_ROOT/monitoring/alertmanager.yaml"

# Grafana admin password - generate, don't hardcode.
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  PASS="$(openssl rand -base64 24)"
  kubectl create secret generic grafana-admin \
    --namespace monitoring \
    --from-literal=password="$PASS"
  echo "    Grafana admin password: $PASS"
  echo "    (store this in Secret Manager, then forget it)"
fi
kubectl apply -f "$OPS_ROOT/monitoring/grafana-dashboards.yaml"

# Dashboards live in Git, not in Grafana's database. A dashboard built by
# clicking in the UI dies with the pod.
kubectl create configmap grafana-dashboards \
  --namespace monitoring \
  --from-file="$OPS_ROOT/monitoring/dashboards/" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$OPS_ROOT/monitoring/grafana.yaml"

echo "==> 5/5 Waiting for monitoring to come up"
kubectl rollout status deployment/prometheus   -n monitoring --timeout=5m
kubectl rollout status deployment/alertmanager -n monitoring --timeout=3m
kubectl rollout status deployment/grafana      -n monitoring --timeout=3m

echo
echo "==> Bootstrap complete."
echo "    Prometheus: kubectl port-forward -n monitoring svc/prometheus 9090:9090"
echo "    Grafana:    kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo
echo "    NOTE: the SLO rules reference metrics your services emit. Until you"
echo "    deploy a service and send it traffic, the rules evaluate to NaN and"
echo "    alerts stay silent. That is expected, not a bug."
