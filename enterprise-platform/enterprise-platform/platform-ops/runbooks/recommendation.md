# Runbook: recommendation

**Tier:** 3
**Availability SLO:** 99.0% over 30 days
**Latency SLO:** 400ms
**Error budget:** 432.0 minutes of full downtime per 30 days

---

## What this service does

Suggests products. Degrades to an empty list if the catalog is unavailable — the page still renders.

**Depends on:** product-catalog
**Called by:** frontend

---

## Alert: RecommendationErrorBudgetFastBurn

### What it means
The service is returning 5xx at more than 14.4x the sustainable rate. If
nothing changes, the entire 30-day error budget is gone in roughly two days.

This is a **page**. It fired because *both* the 5-minute and 1-hour windows
breached, so it is not a scrape blip.

### First 5 minutes

```bash
# 1. Is it one pod or all of them?
kubectl get pods -n prod -l app=recommendation -o wide

# 2. What changed? Almost always the answer.
kubectl rollout history deployment/recommendation -n prod
kubectl get deployment recommendation -n prod \
  -o jsonpath='{.metadata.annotations.platform/git-commit}'

# 3. Actual errors, not guesses
kubectl logs -n prod -l app=recommendation --tail=100 | grep -i error
```

### If a deploy went out in the last hour

Roll back first, investigate second. This is not defeat, it is the correct
order of operations.

```bash
kubectl rollout undo deployment/recommendation -n prod
kubectl rollout status deployment/recommendation -n prod
```

### If no deploy went out

Check the dependencies. This service calls: product-catalog

```bash
# Is a dependency the real source?
kubectl get pods -n prod -l app=<dependency>

# Our dependency metrics tell you directly:
#   dependency_requests_total{dependency="...",status="failure"}
```

### If it's resource pressure

```bash
kubectl top pods -n prod -l app=recommendation
kubectl describe pod -n prod -l app=recommendation | grep -A5 "Last State"
```

OOMKilled means the memory limit is too low, or there's a leak. On this
2-node cluster, check node allocatable before raising the limit:

```bash
kubectl describe nodes | grep -A5 "Allocated resources"
```

---

## Alert: RecommendationErrorBudgetSlowBurn

Not urgent. Do **not** page. Open a ticket and investigate during working
hours. It means something is quietly wrong — an edge case, a slow leak, a
dependency degrading.

---

## Alert: RecommendationLatencySLOBreach

```bash
# Where is time going? Check the dependency call rate first.
# In Prometheus:
#   histogram_quantile(0.99,
#     sum by (le) (rate(http_request_duration_seconds_bucket{app="recommendation"}[5m])))
```

Common causes, in the order they actually happen:
1. A dependency got slower and we're waiting on it
2. CPU throttling — but note we set **no CPU limit**, so this shouldn't be it
3. The HPA is maxed and each pod is overloaded
4. Someone added a synchronous call to a hot path

---

## Alert: RecommendationErrorBudgetExhausted

The 30-day budget is gone. Per the error budget policy:

- **Freeze feature releases** for this service
- Only reliability work and rollbacks ship
- The freeze lifts when the trailing 30-day window recovers

This is the policy working, not a punishment. If this fires often, the SLO
is either wrong or the service genuinely needs investment. Both are worth
knowing.

---

## Useful queries

```promql
# Current error budget remaining (1.0 = untouched, 0 = gone)
slo:recommendation:error_budget_remaining

# Error rate right now
1 - slo:recommendation:success_ratio5m

# Which downstream is failing?
sum by (dependency, status) (
  rate(dependency_requests_total{app="recommendation"}[5m])
)

# Request rate by status
sum by (status_code) (rate(http_requests_total{app="recommendation"}[5m]))
```

---

## Escalation

| When | Who |
|---|---|
| Rollback didn't fix it in 15 min | Platform on-call secondary |
| Dependency owned by another team | That team's on-call |
| Suspected data loss or corruption | Incident commander, declare SEV1 |

## Related

- Dashboard: Grafana → `recommendation overview`
- Repo: `svc-recommendation`
- Deploy: `./scripts/deploy.sh prod`
