    # svc-shipping

    Shipping cost and delivery estimates by zone.

    **Stack:** Python 3.12 / FastAPI
    **Tier:** 2 · **Availability SLO:** 99.5% over 30 days
    **Runbook:** `platform-ops/runbooks/shipping.md`

    ---

    ## Where it sits

    **Calls:** _none_
    **Called by:** `checkout`

    ## API

    | Method | Path | Purpose |
|---|---|---|
| POST | `/api/shipping/quote` | Quote by address + items |
| GET | `/api/shipping/zones` | Zone rate card |

    ### Platform endpoints (every service has these)

    | Path | Purpose |
    |---|---|
    | `/healthz` | Liveness. Never checks dependencies — that would cause restart storms. |
    | `/readyz` | Readiness. Returns 503 while starting or draining. |
    | `/metrics` | Prometheus. Feeds the SLO rules in `platform-ops/slo/`. |

    ---

    ## Run it locally

    ```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest                # coverage.xml is written for SonarQube
uvicorn src.main:app --reload --port 8080
```

    ## Build the image

    ```bash
    docker build -t svc-shipping:local .
    docker run -p 8080:8080 svc-shipping:local
    curl localhost:8080/healthz
    ```

    ---

    ## Deploy

    Deployment is **branch-driven**. You do not deploy by hand in normal operation.

    | Branch | Environment | Gate |
    |---|---|---|
    | `develop` | `dev` | Automatic |
    | `staging` | `staging` | Automatic (PR + 1 approval to merge) |
    | `main` | `prod` | PR + approval, then **manual input gate** in Jenkins, then canary |

    Manual deploy (for learning or emergencies):

    ```bash
    export IMAGE_URL="asia-south1-docker.pkg.dev/PROJECT/dev-microservices/svc-shipping:sometag"
    export IMAGE_TAG="sometag"
    export PROJECT_ID="your-project"
    ./scripts/deploy.sh dev

    # See exactly what would be applied, without applying it:
    ./scripts/deploy.sh dev --dry-run
    ```

    ### How the templating works (no Helm, no Kustomize)

    `k8s/base/*.yaml` contain `${VARIABLE}` placeholders. `k8s/env/<env>.env`
    supplies the values. `scripts/deploy.sh` runs `envsubst` to render them, then
    `kubectl apply`.

    ```
    k8s/base/deployment.yaml   +   k8s/env/prod.env   =   rendered manifest
             (template)                 (values)              (applied)
    ```

    That is, honestly, most of what Helm's values mechanism does for most teams.
    What we give up: dependency management, packaging, `helm rollback`, and the
    ecosystem of published charts. `deploy.sh` compensates with an explicit
    rollout gate and automatic `kubectl rollout undo` on failure.

    The script also **fails loudly if any `${VAR}` is left unsubstituted** —
    without that check you silently apply a manifest with a literal `${IMAGE_URL}`
    as the image name, and spend twenty minutes reading `ImagePullBackOff`.

    ---

    ## What's in `k8s/base/`

    | File | Why it exists |
    |---|---|
    | `serviceaccount.yaml` | Workload Identity binding — pod gets GCP creds, no key file |
    | `deployment.yaml` | Probes, spread across both nodes, non-root, read-only rootfs |
    | `service.yaml` | ClusterIP. Selects on `app`, not `version`, so canaries work |
    | `hpa.yaml` | Scale up fast, down slow |
    | `pdb.yaml` | Protects against node drains taking the service down |
    | `networkpolicy.yaml` | Only real callers may reach us; only real deps are reachable |

    ### Two decisions worth knowing about

    **No CPU limit, memory limit only.** CPU is compressible — a limit causes
    throttling that looks exactly like a latency bug and wastes days of
    debugging. Memory is not compressible, so it is capped: an OOMKill of one
    pod beats a node going down and taking half a 2-node cluster with it.

    **Liveness never checks dependencies.** If the catalog is down, restarting
    this pod fixes nothing and turns a partial outage into a total one. Liveness
    asks "am I wedged?"; readiness asks "should I get traffic?".



    ---

    ## Pipeline

    `Jenkinsfile` — declarative, no shared library (per project constraint).

    ```
    Checkout → Install → Lint → Test → Sonar scan → Quality gate (BLOCKS)
      → Build image → Trivy (HIGH/CRITICAL blocks) → Push to Artifact Registry
      → Deploy (branch-mapped) → [prod: approval → canary] → Smoke test
    ```

    The quality gate and the Trivy gate are what make this more than theatre:
    both stop the build rather than printing a warning nobody reads.

    > **Trade-off, stated plainly:** with no shared library, this Jenkinsfile is
    > duplicated across 10 repos. Changing the pipeline is a 10-repo change. In a
    > real organisation that pain is exactly what justifies a shared library.
