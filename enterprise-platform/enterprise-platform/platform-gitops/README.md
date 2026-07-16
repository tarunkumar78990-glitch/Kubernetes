# platform-gitops

**The single source of truth for what runs in the cluster.**

Every file under `envs/` is a **fully rendered** Kubernetes manifest — no
`${VARIABLES}`, no templating, no plugins. What you read here is exactly what
is applied.

```
envs/
  dev/
    cart/
      deployment.yaml     <- rendered, real image tag, real replica count
      service.yaml
      ...
    checkout/
    ...
  staging/
  prod/
argocd/
  projects.yaml           <- one AppProject per environment
  applicationsets/        <- generates 30 Applications from the tree above
```

---

## Nobody edits this repo by hand

Jenkins writes it. The flow:

```
svc-cart (source)                     platform-gitops (state)
     │                                        │
  Jenkins CI                                  │
  test -> sonar -> trivy -> push image        │
     │                                        │
     └── envsubst renders manifests ─────────►│  commit
                                              │
                                         Argo CD (pull)
                                              │
                                              ▼
                                          cluster
```

**Jenkins never touches the cluster.** It commits YAML. Argo CD pulls.

## Why rendered, not templated

Argo CD can render with Helm, Kustomize, a plain directory, or a config
management plugin. Our manifests are `envsubst` templates, and this project
forbids Helm and Kustomize — so a "plain directory" would apply the literal
string `${IMAGE_URL}` as the image name.

Two ways out:

| | Rendered manifests (chosen) | Config management plugin |
|---|---|---|
| Where envsubst runs | Jenkins, at CI time | Argo CD sidecar, at sync time |
| Repo contents | Final YAML | Templates + env files |
| Diff in a PR | The **actual change** | A variable changed, effect unknown |
| Argo CD complexity | None — plain directory | Custom sidecar image, plugin config |
| Debugging a bad render | `git diff` | Read sidecar logs |

We render. The diff being reviewable is the point — a reviewer sees
`image: ...:dev-42` become `image: ...:dev-43`, not `IMAGE_TAG` changing in a
file they have to mentally evaluate.

The trade-off: **repo churn.** Every build commits. That's normal for this
pattern, and `git log envs/prod/cart/` becomes a perfect audit trail of what
ran in prod and when.

## How to roll back

```bash
git revert <commit>
git push
```

Argo CD syncs within ~3 minutes. That's the rollback. No kubectl.

## Sync policies

| Env | Policy | Why |
|---|---|---|
| `dev` | automated + prune + selfHeal | Move fast. Drift is reverted immediately. |
| `staging` | automated + prune + selfHeal | Same, so staging genuinely mirrors prod's process. |
| `prod` | **manual** | The sync button IS the approval gate. |
