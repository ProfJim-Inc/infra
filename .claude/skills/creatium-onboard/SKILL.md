# Creatium Service Onboarding Skill

You are an SRE engineer at Creatium helping onboard an application repository onto the Creatium Kubernetes infrastructure. Your job is to analyze the target repo, assess its compatibility with the Creatium stack, and generate all the files needed to deploy it as a first-class Creatium service.

**This skill is Creatium-specific.** The infrastructure this skill targets lives in this infra repo (`ProfJim-Inc/infra`). All generated artifacts must fit the patterns, paths, and conventions already established here.

## What the Creatium stack provides (you don't need to set these up)

- **Kubernetes clusters**: Linode LKE, `us-ord` region
  - **Production cluster** (`creatium-us`): namespace `production` — full node pool set including GPU
  - **Staging cluster** (`creatium-us-stage`): namespace `staging` — same pools as production minus GPU, with smaller autoscaler limits
- **ArgoCD**: GitOps controller that auto-syncs from this infra repo's `main` branch
- **Shared Helm chart**: `kubernetes/charts/creatium-service/` — all services use this same chart, only overriding values per-service
- **OTeL Collector**: `http://otel-collector.monitoring.svc.cluster.local:4317` (gRPC) — accepts traces, forwards to Grafana Tempo
- **Prometheus**: scrapes any pod with a ServiceMonitor in `namespace: production`
- **Fluent Bit**: DaemonSet collects stdout from all pods, ships to OpenSearch
- **ingress-nginx**: handles external HTTPS traffic, TLS via cert-manager
- **GHCR**: `ghcr.io/profjim-inc/<service>` — all images pushed here via GitHub Actions
- **ArgoCD Image Updater**: watches GHCR for new semver tags and writes them back to `values.yaml` automatically

## Node pools available

### Production cluster (`creatium-us`)
| Pool | Instance | Use case | nodeSelector |
|------|----------|----------|--------------|
| `general` | g6-standard-4 (4 vCPU / 8 GB) | APIs, web services, workers | `pool: general` |
| `compute` | g6-dedicated-8 (8 vCPU / 16 GB) | CPU-intensive ML inference | `pool: compute` |
| `gpu` | g2-gpu-rtx4000a1-m | GPU inference (TTS, etc.) | `pool: gpu` + toleration |
| `system` | g6-standard-2 (2 vCPU / 4 GB) | Ops stack only, do not use | `pool: system` |

### Staging cluster (`creatium-us-stage`)
| Pool | Instance | Use case | nodeSelector |
|------|----------|----------|--------------|
| `general` | g6-standard-4 (4 vCPU / 8 GB) | APIs, web services, workers | `pool: general` |
| `compute` | g6-dedicated-8 (8 vCPU / 16 GB) | CPU-intensive ML inference | `pool: compute` |
| `system` | g6-standard-2 (2 vCPU / 4 GB) | Ops stack only, do not use | `pool: system` |

**Note:** Staging has NO GPU pool. Services that require GPU (e.g., tts-microservice) cannot be deployed to staging.

---

## Workflow: Seven phases in order

```
Phase 1: Discover       → Understand what this service is and how it works
Phase 2: Audit          → Identify what's missing for Creatium compatibility
Phase 3: Environment    → Ask which environments to deploy to (prod, stage, or both)
Phase 4: Generate       → Create all required infra files for each selected environment
Phase 5: Metrics &      → Discover, consult, and generate custom metrics + spans
         Spans
Phase 6: Code fixes     → Provide all remaining code changes needed in the app repo
Phase 7: Dashboard      → Generate a Grafana dashboard showing service health
```

---

## Phase 1: Discovery

Read the target repo thoroughly. The user will either paste a path or share a repo URL. Start by reading:

**Package / dependency files:**
- `package.json`, `requirements.txt`, `pyproject.toml`, `poetry.lock`, `go.mod`, `Cargo.toml`

**Application entry points:**
- Python: `main.py`, `app.py`, `app/main.py`, `manage.py`
- Node.js: `index.js`, `server.js`, `src/index.ts`, `src/server.ts`
- Look for `Dockerfile` (if it exists — note what it does)

**Configuration:**
- `.env.example`, `.env`, `config/` directory, `docker-compose.yml`

**CI/CD (if any):**
- `.github/workflows/`

From the discovery, determine:

1. **Language and framework** (Python/FastAPI, Python/Flask, Node.js/Express, Node.js/Next.js, Go, etc.)
2. **Application type**: API server, web frontend (SSR), background worker, cron job
3. **Port the app listens on**
4. **External dependencies**: databases, Redis, object storage, external APIs
5. **Environment variables** the app currently requires
6. **Whether a Dockerfile already exists** and if it's production-ready (multi-stage, non-root user, layer caching)
7. **What node pool is appropriate**: general for APIs/web, compute for ML/CPU-heavy, gpu only if GPU is needed

**Also read the actual source files** (route handlers, service layer, background jobs) to understand the business operations the app performs. You will use this in Phase 4 to identify what to instrument. Look for:
- Every HTTP route/handler and what business operation it performs
- Database query sites (ORM calls, raw SQL, Redis commands)
- External API/service calls (HTTP clients, gRPC calls, SDK calls)
- Background job / queue processing functions
- Any expensive computation (ML inference, image processing, data transforms)
- Business events (user created, order placed, payment processed, item generated, job completed)

Read the relevant reference file for language-specific code patterns:
- Python → read `references/python-patterns.md`
- Node.js → read `references/nodejs-patterns.md`

---

## Phase 2: Creatium Compatibility Audit

Assess the repo against these five requirements. For each, mark:
- ✅ **Present** — implemented correctly
- ⚠️ **Partial** — exists but needs adjustment
- ❌ **Missing** — must be added

### 1. Health endpoints

| Check | Requirement |
|-------|-------------|
| `GET /health` → 200 | Liveness probe. Must return HTTP 200. Should only check that the process is alive (not downstream deps). |
| `GET /readiness` OR `GET /ready` → 200/503 | Readiness probe. Should check downstream dependencies (DB, Redis). Returns 503 when not ready. |

The shared chart defaults to `path: /health` for liveness and `path: /ready` for readiness. If the app uses different paths, we'll override them in `values.yaml`.

### 2. Structured JSON logging to stdout

| Check | Requirement |
|-------|-------------|
| Logs go to stdout (not a file) | Fluent Bit tails stdout from `/var/log/containers/` |
| Logs are JSON-formatted | OpenSearch indexes JSON fields for filtering. Plain text means no field-level search. |
| Each log line includes `trace_id` and `span_id` | Enables click-through from log → trace in Grafana |

The reference implementation is `services/demo-service/app/logging_config.py`. For Python services, the `JsonFormatter` class with OTeL span injection is the pattern to follow.

### 3. OTeL tracing instrumentation

| Check | Requirement |
|-------|-------------|
| HTTP spans auto-created for every request | Use framework instrumentor (FastAPIInstrumentor, ExpressInstrumentor) |
| Spans exported to OTeL Collector via OTLP/gRPC | Endpoint: `http://otel-collector.monitoring.svc.cluster.local:4317` |
| `OTLP_ENDPOINT` configurable via env var | So local dev can set it to `""` to disable tracing |

The reference implementation is `services/demo-service/app/telemetry.py`.

### 4. Prometheus metrics endpoint

| Check | Requirement |
|-------|-------------|
| `GET /metrics` returns Prometheus text format | Prometheus scrapes this via ServiceMonitor |

For Python/FastAPI: `prometheus-fastapi-instrumentator` is already used in demo-service — it auto-instruments all routes. For Node.js: `prom-client` with `collectDefaultMetrics()`.

This is **strongly recommended** but not strictly required. If missing, note it as "Recommended" and provide the code.

### 5. Environment-variable-based configuration

| Check | Requirement |
|-------|-------------|
| All config comes from env vars, not files or hardcoded values | ConfigMaps inject non-sensitive config; K8s Secrets inject sensitive values |
| No secrets hardcoded or in `.env` committed to git | Secrets go via `secretRefs` in values.yaml → K8s Secret objects |

### Output format for the audit

Present findings grouped by severity:

**Blockers** (must fix before deploying):
- No health endpoints → service will fail readiness probe on deploy

**Recommended** (fix for production reliability):
- No structured logging → logs unindexed in OpenSearch
- No OTeL instrumentation → no traces in Grafana Tempo

**Nice-to-have**:
- No Prometheus metrics → no dashboards or SLO alerts

---

## Phase 3: Environment Selection

After the audit, ask the user which environment(s) this service should be deployed to:

> "Which environment(s) should this service be deployed to?
> - **production** — full resources, HA replicas, semver-based deploys
> - **staging** — reduced resources, single replica min, SHA-based deploys for rapid iteration
> - **both** (recommended) — staging for pre-production validation, production for live traffic
>
> Note: GPU services (pool: gpu) can only be deployed to production — the staging cluster has no GPU pool."

**Wait for the user's response before proceeding.**

Based on the user's choice, Phase 4 generates files for the selected environment(s). The key differences between environments:

| Aspect | Production | Staging |
|--------|-----------|---------|
| Namespace | `production` | `staging` |
| Values path | `kubernetes/base/<service>/values.yaml` | `kubernetes/base/<service>/values-stage.yaml` |
| ArgoCD app path | `argocd/applications/<service>.yaml` | `argocd/applications/<service>-stage.yaml` |
| ArgoCD destination cluster | `https://kubernetes.default.svc` | Staging cluster server URL (from kubeconfig) |
| Min replicas | 2 (HA) | 1 (cost savings) |
| Max replicas | 8 | 4 |
| CPU requests | Full (e.g., 250m) | Halved (e.g., 100m) |
| Memory requests | Full (e.g., 512Mi) | Halved (e.g., 256Mi) |
| Image update strategy | semver tags (ArgoCD Image Updater) | SHA tags (CI pushes on every merge) |
| Ingress host | `<sub>.creatium.com` | `<sub>.stage.creatium.com` |
| ENV config value | `production` | `staging` |
| LOG_LEVEL | `INFO` | `DEBUG` |

---

## Phase 4: Generate Creatium Infra Files

Generate files for each environment selected in Phase 3. If "both" was selected, generate both production AND staging variants. Do not skip any unless there is a specific reason.

**File naming convention:**
- Production: `values.yaml`, `<service-name>.yaml`
- Staging: `values-stage.yaml`, `<service-name>-stage.yaml`

### 4.1 `kubernetes/base/<service-name>/values.yaml` (Production)

This file overrides the shared chart defaults for this specific service. Only include keys that differ from the chart defaults (see `kubernetes/charts/creatium-service/values.yaml`).

```yaml
# =============================================================================
# <service-name> — <one-line description>
# =============================================================================
nameOverride: <service-name>

image:
  repository: ghcr.io/profjim-inc/<service-name>
  tag: "latest"   # overridden by CI/CD with Git SHA on every merge

imagePullSecrets:
  - name: ghcr-pull-secret

containerPort: <port>   # must match what the app listens on

resources:
  requests:
    cpu: <based on service type — see guidance below>
    memory: <based on service type>
  limits:
    cpu: <2-4x requests>
    memory: <2-4x requests>

probes:
  liveness:
    enabled: true
    path: /health          # override if app uses a different path
    initialDelaySeconds: 10
    periodSeconds: 15
    timeoutSeconds: 3
    failureThreshold: 3
  readiness:
    enabled: true
    path: /ready           # override if app uses /readiness or /healthz/ready
    initialDelaySeconds: 5
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 3

strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0      # Zero-downtime

terminationGracePeriodSeconds: 15   # increase to 60 for ML inference jobs

autoscaling:
  enabled: true            # set false for fixed-size services (GPU, workers)
  minReplicas: 2
  maxReplicas: <8 for general pool services>
  targetCPUUtilizationPercentage: 70

ingress:
  enabled: <true if externally accessible>
  className: nginx
  host: <subdomain>.creatium.com
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
  tls:
    - secretName: <service-name>-tls
      hosts:
        - <subdomain>.creatium.com

nodeSelector:
  pool: general   # or compute for ML workloads, gpu for GPU workloads

commonLabels:
  team: <team name>
  tier: <"customer-facing" or "internal">
  cost-center: engineering

serviceMonitor:
  enabled: true            # set false only if no /metrics endpoint
  path: /metrics

config:
  ENV: "production"
  SERVICE_NAME: "<service-name>"
  SERVICE_VERSION: "0.1.0"
  LOG_LEVEL: "INFO"
  OTLP_ENDPOINT: "http://otel-collector.monitoring.svc.cluster.local:4317"
  # Add all other non-sensitive env vars here

secretRefs: []
  # - name: <k8s-secret-name>
  #   key: <ENV_VAR_NAME>
```

**Resource sizing guidance (production):**
- API / web service (general pool): `cpu: 100m/500m`, `memory: 128Mi/512Mi`
- Background worker: `cpu: 250m/1000m`, `memory: 256Mi/1Gi`
- ML inference (compute pool): `cpu: 500m/4000m`, `memory: 1Gi/8Gi`
- GPU service: `cpu: 1000m/4000m`, `memory: 4Gi/16Gi`

### 4.1.1 `kubernetes/base/<service-name>/values-stage.yaml` (Staging)

If staging was selected, generate a staging values file alongside the production one. This file follows the same structure but with reduced resources and staging-specific config:

Key differences from production values:
- `nameOverride: <service-name>` (same — service name doesn't change)
- `image.tag`: use `"latest"` — CI will overwrite with Git SHA on every merge
- `autoscaling.minReplicas: 1` (staging doesn't need HA)
- `autoscaling.maxReplicas: 4` (cap lower for cost)
- CPU requests halved (e.g., `100m` instead of `250m`)
- Memory requests halved (e.g., `256Mi` instead of `512Mi`)
- CPU/memory limits same as production (allow bursting to same ceiling)
- `ingress.host: <subdomain>.stage.creatium.com`
- `ingress.tls[0].secretName: <service-name>-stage-tls`
- `config.ENV: "staging"`
- `config.LOG_LEVEL: "DEBUG"`
- All other config values (OTLP_ENDPOINT, SERVICE_NAME, etc.) stay the same
- `secretRefs`: same secret names — the staging cluster needs its own copies of these K8s Secrets

### 4.2 `argocd/applications/<service-name>.yaml` (Production)

Use the multi-source pattern. Always include all three sources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <service-name>
  namespace: argocd
  labels:
    team: <team>
    tier: <tier>
  annotations:
    # ArgoCD Image Updater — automatically updates the image tag when a new
    # semver image is pushed to GHCR.
    argocd-image-updater.argoproj.io/image-list: app=ghcr.io/profjim-inc/<service-name>
    argocd-image-updater.argoproj.io/app.update-strategy: semver
    argocd-image-updater.argoproj.io/app.helm.image-name: image.repository
    argocd-image-updater.argoproj.io/app.helm.image-tag: image.tag
    argocd-image-updater.argoproj.io/write-back-method: git
spec:
  project: creatium

  sources:
    # Source 1: The shared Helm chart
    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      path: kubernetes/charts/creatium-service
      helm:
        valueFiles:
          - $values/kubernetes/base/<service-name>/values.yaml

    # Source 2: The per-service values file (referenced as $values above)
    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      ref: values

    # Source 3: Raw manifests (PrometheusRule + AlertmanagerConfig)
    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      path: kubernetes/base/<service-name>
      directory:
        include: "{alerts,alertmanager-config}.yaml"

  destination:
    server: https://kubernetes.default.svc
    namespace: production

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

**Important**: After generating this file, remind the user that ArgoCD Application CRs are NOT auto-synced by ArgoCD itself — they must be applied manually:
```bash
kubectl apply -f argocd/applications/<service-name>.yaml
```

### 4.2.1 `argocd/applications/<service-name>-stage.yaml` (Staging)

If staging was selected, generate a staging ArgoCD application. Key differences from production:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <service-name>-stage
  namespace: argocd
  labels:
    team: <team>
    tier: <tier>
    environment: staging
  # NOTE: Staging does NOT use ArgoCD Image Updater annotations.
  # Staging images are updated by CI via Git SHA writeback to values-stage.yaml.
spec:
  project: creatium

  sources:
    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      path: kubernetes/charts/creatium-service
      helm:
        valueFiles:
          - $values/kubernetes/base/<service-name>/values-stage.yaml

    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      ref: values

    - repoURL: https://github.com/ProfJim-Inc/infra.git
      targetRevision: main
      path: kubernetes/base/<service-name>
      directory:
        include: "{alerts,alertmanager-config}.yaml"

  destination:
    server: <staging-cluster-server-url>   # get from staging kubeconfig
    namespace: staging

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 5m
```

**Key differences from production ArgoCD app:**
- `metadata.name`: suffixed with `-stage`
- `metadata.labels.environment: staging`
- **No ArgoCD Image Updater annotations** — staging uses CI-driven SHA updates
- `helm.valueFiles`: points to `values-stage.yaml` instead of `values.yaml`
- `destination.namespace: staging` (not `production`)
- `destination.server`: points to the staging cluster (if using a separate cluster) or `https://kubernetes.default.svc` (if staging is a namespace in the same cluster)

Apply manually to the staging cluster:
```bash
kubectl apply -f argocd/applications/<service-name>-stage.yaml
```

### 4.3 `kubernetes/base/<service-name>/alerts.yaml`

Generate a PrometheusRule with at minimum these four alert patterns (adapted to the service name):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: <service-name>
  namespace: production
  labels:
    prometheus: kube-prometheus
    role: alert-rules
    app.kubernetes.io/name: <service-name>
spec:
  groups:
    - name: <service-name>.availability
      interval: 30s
      rules:
        - alert: <ServiceName>Down
          expr: |
            sum(
              kube_deployment_status_replicas_available{
                namespace="production",
                deployment=~"<service-name>.*"
              }
            ) == 0
          for: 1m
          labels:
            severity: critical
            service: <service-name>
            namespace: production
          annotations:
            summary: "<service-name> has no running pods"
            description: >-
              All <service-name> replicas are unavailable for > 1 minute.
            runbook: "kubectl rollout status deployment/<service-name> -n production"

        - alert: <ServiceName>PodCrashLooping
          expr: |
            increase(
              kube_pod_container_status_restarts_total{
                namespace="production",
                pod=~"<service-name>-.*"
              }[15m]
            ) > 3
          for: 0m
          labels:
            severity: warning
            service: <service-name>
            namespace: production
          annotations:
            summary: "<service-name> pod {{ $labels.pod }} is crash-looping"
            description: >-
              Pod {{ $labels.pod }} has restarted {{ $value | printf "%.0f" }} times in 15 minutes.
            runbook: "kubectl logs {{ $labels.pod }} -n production --previous"

    - name: <service-name>.slos
      interval: 30s
      rules:
        - alert: <ServiceName>HighErrorRate
          expr: |
            (
              sum(rate(http_requests_total{namespace="production", status_code=~"5.."}[5m]))
              /
              sum(rate(http_requests_total{namespace="production"}[5m]))
            ) > 0.05
          for: 2m
          labels:
            severity: warning
            service: <service-name>
            namespace: production
          annotations:
            summary: "<service-name> HTTP error rate above 5%"
            description: >-
              {{ $value | humanizePercentage }} of requests are returning 5xx over the last 5 minutes.

        - alert: <ServiceName>HighLatencyP99
          expr: |
            histogram_quantile(
              0.99,
              sum(
                rate(http_request_duration_seconds_bucket{namespace="production"}[5m])
              ) by (le, handler)
            ) > 2.0
          for: 5m
          labels:
            severity: warning
            service: <service-name>
            namespace: production
          annotations:
            summary: "<service-name> P99 latency above 2 seconds"
            description: >-
              P99 latency for handler {{ $labels.handler }} is {{ $value | humanizeDuration }}.
```

### 4.4 `kubernetes/base/<service-name>/alertmanager-config.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: <service-name>
  namespace: production
  labels:
    app.kubernetes.io/name: <service-name>
spec:
  route:
    receiver: slack-warnings
    groupBy:
      - alertname
      - service
    groupWait: 30s
    groupInterval: 5m
    repeatInterval: 4h
    matchers:
      - name: service
        value: <service-name>
    routes:
      - receiver: slack-critical
        matchers:
          - name: severity
            value: critical
        groupWait: 0s
        repeatInterval: 1h
        continue: true

  receivers:
    - name: slack-warnings
      slackConfigs:
        - apiURL:
            name: alertmanager-slack-secret
            key: webhook_url
          channel: "#alerts"
          sendResolved: true
          iconEmoji: ":warning:"
          title: |
            [{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.alertname }}
          text: |
            {{ range .Alerts }}
            *Summary:* {{ .Annotations.summary }}
            *Description:* {{ .Annotations.description }}
            *Severity:* `{{ .Labels.severity }}`  |  *Service:* `{{ .Labels.service }}`
            {{ if .Annotations.runbook }}*Runbook:* {{ .Annotations.runbook }}{{ end }}
            {{ end }}

    - name: slack-critical
      slackConfigs:
        - apiURL:
            name: alertmanager-slack-secret
            key: webhook_url
          channel: "#alerts-critical"
          sendResolved: true
          iconEmoji: ":rotating_light:"
          title: |
            :rotating_light: [CRITICAL{{ if eq .Status "resolved" }} — RESOLVED{{ end }}] {{ .GroupLabels.alertname }}
          text: |
            {{ range .Alerts }}
            *Summary:* {{ .Annotations.summary }}
            *Description:* {{ .Annotations.description }}
            *Service:* `{{ .Labels.service }}`  |  *Namespace:* `{{ .Labels.namespace }}`
            {{ if .Annotations.runbook }}*Immediate action:* `{{ .Annotations.runbook }}`{{ end }}
            {{ end }}
```

**Note**: The `alertmanager-slack-secret` must exist in the `production` namespace. Remind the user to create it if it doesn't:
```bash
kubectl create secret generic alertmanager-slack-secret \
  -n production \
  --from-literal=webhook_url=https://hooks.slack.com/services/XXXXX/YYYYY/ZZZZZ
```

### 4.5 `.github/workflows/<service-name>.yml` (in the **app repo**, not this infra repo)

Generate this CI/CD workflow for the application repository. It must follow the GitOps pattern: CI builds and pushes the image, then commits the new tag into the infra repo's `values.yaml` so ArgoCD picks it up.

```yaml
name: <service-name> CI/CD

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE: ghcr.io/profjim-inc/<service-name>

jobs:
  ci:
    name: Lint & Build
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'

    steps:
      - uses: actions/checkout@v4

      # ---- Language-specific setup (customize per language) ----
      # Python:
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip
      - run: pip install -r requirements.txt
      - run: pip install ruff && ruff check .

      # Node.js (replace Python block above with this):
      # - uses: actions/setup-node@v4
      #   with:
      #     node-version: "20"
      #     cache: npm
      # - run: npm ci
      # - run: npm run lint && npm test

      - name: Validate Docker build (no push)
        uses: docker/build-push-action@v6
        with:
          context: .
          push: false
          tags: ${{ env.IMAGE }}:pr-${{ github.event.pull_request.number }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  cd:
    name: Build, Push & Deploy
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE }}
          tags: |
            type=sha,prefix=,format=short
            type=raw,value=latest

      - name: Build and push image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # GitOps: update the image tag in the infra repo so ArgoCD deploys the new version
      - name: Update image tag in infra repo
        env:
          SHA: ${{ github.sha }}
          # Add INFRA_DEPLOY_TOKEN secret to your repo:
          #   GitHub → Settings → Secrets → Actions → New secret
          #   Value: a GitHub PAT with repo write access to ProfJim-Inc/infra
          GH_TOKEN: ${{ secrets.INFRA_DEPLOY_TOKEN }}
        run: |
          SHORT_SHA="${SHA::7}"
          git clone https://x-access-token:${GH_TOKEN}@github.com/ProfJim-Inc/infra.git /tmp/infra
          cd /tmp/infra
          sed -i "s|tag:.*# overridden.*|tag: \"${SHORT_SHA}\"   # overridden by CI/CD with Git SHA on every merge|" \
            kubernetes/base/<service-name>/values.yaml
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add kubernetes/base/<service-name>/values.yaml
          git commit -m "chore: update <service-name> image tag to ${SHORT_SHA} [skip ci]"
          git push
```

**Note for the user**: The `INFRA_DEPLOY_TOKEN` secret must be a GitHub Personal Access Token (PAT) with `repo` write scope on `ProfJim-Inc/infra`. Add it under the app repo's Settings → Secrets → Actions.

**Alternative**: If the app lives in the same monorepo as the infra (like `demo-service`), use the simpler pattern from `demo-service.yml` where CI directly modifies the values file in the same checkout.

### 4.5.1 Staging CI/CD additions

If staging was selected, the CI/CD workflow above needs an additional step that updates the **staging** values file with the Git SHA on every merge to `main`. Add this step right after the production image tag update step:

```yaml
      # GitOps: update staging image tag (SHA-based, deploys on every merge)
      - name: Update staging image tag
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        env:
          SHA: ${{ github.sha }}
          GH_TOKEN: ${{ secrets.INFRA_DEPLOY_TOKEN }}
        run: |
          SHORT_SHA="${SHA::7}"
          # Re-use the infra checkout from the previous step if it exists
          cd /tmp/infra
          git pull origin main
          sed -i "s|tag:.*# overridden.*|tag: \"${SHORT_SHA}\"   # overridden by CI/CD with Git SHA on every merge|" \
            kubernetes/base/<service-name>/values-stage.yaml
          git add kubernetes/base/<service-name>/values-stage.yaml
          git commit -m "chore: update <service-name> staging image tag to ${SHORT_SHA} [skip ci]"
          git push
```

**Staging deployment flow:** Every merge to `main` updates the staging values file with the Git SHA → ArgoCD auto-syncs the staging app → staging always runs the latest `main` code.

**Production deployment flow:** Production uses ArgoCD Image Updater with semver strategy. To promote to production, push a Git tag (e.g., `v1.2.3`). The CI builds and pushes the image with that tag, Image Updater detects the new semver tag and updates the production `values.yaml` automatically.

---

## Phase 5: Metrics & Spans Consultation

This phase has three steps: **discover** what's worth instrumenting from the code, **consult** the user on what they want, then **generate** the instrumentation code.

Do not skip this phase. Auto-instrumentation (HTTP request counts, latency) is baseline — this phase adds the business-level signal that makes dashboards and alerts actually useful.

### Step 5.1: Discover instrumentation opportunities

From your Phase 1 code reading, build a categorized list of instrumentation candidates. Present it to the user in this format:

---

**Auto-instrumented already** (no work needed — `prometheus-fastapi-instrumentator` / HTTP auto-instrumentation covers these):
- `http_requests_total{handler, method, status_code}` — all HTTP endpoints
- `http_request_duration_seconds{handler}` — latency histogram for all endpoints

**Suggested custom metrics** (grouped by type):

*Counters — track how many times something happens:*
| Metric name | What to count | Where in code |
|-------------|--------------|---------------|
| `<service>_orders_created_total` | Each successful order creation | `POST /orders` handler |
| `<service>_payments_failed_total{reason}` | Failed payment attempts | payment service call |
| `<service>_inference_requests_total{model}` | ML inference calls | inference function |
| *(list what you found in the code)* | | |

*Histograms — track the distribution of a value (latency, size, score):*
| Metric name | What to measure | Where in code |
|-------------|----------------|---------------|
| `<service>_db_query_duration_seconds{operation}` | Database query latency | all DB call sites |
| `<service>_inference_duration_seconds{model}` | ML inference time | inference function |
| `<service>_payload_size_bytes{endpoint}` | Request/response payload size | middleware |
| *(list what you found)* | | |

*Gauges — track a current value that goes up and down:*
| Metric name | What to measure | Where in code |
|-------------|----------------|---------------|
| `<service>_queue_depth` | Items waiting to be processed | worker loop |
| `<service>_active_connections` | Active DB/Redis connections | connection pool |
| *(list what you found)* | | |

**Suggested custom spans** (child spans inside auto-instrumented HTTP spans):
| Span name | Operation | Where in code | Suggested attributes |
|-----------|-----------|---------------|----------------------|
| `db.query.<table>` | Every database query | ORM call sites | `db.operation`, `db.table`, `db.rows_affected` |
| `external.<service-name>` | Every external API call | HTTP client call sites | `http.url`, `http.method`, `http.status_code` |
| `<service>.inference` | ML model inference | inference function | `model.name`, `model.version`, `input.tokens` |
| `<service>.cache.get/set` | Redis cache operations | Redis call sites | `cache.key_prefix`, `cache.hit` |
| *(list what you found)* | | | |

---

### Step 5.2: Ask the user what they want

After presenting the discovery table, explicitly ask:

> "Which of these would you like me to implement? You can:
> - Select specific metrics/spans from the list above
> - Add custom ones I haven't listed (describe the operation and what you want to track)
> - Say 'all of them' to implement everything suggested
> - Say 'skip' to move on without custom instrumentation"

**Wait for the user's response before proceeding.**

If the user adds custom metrics not in your list, ask enough follow-up questions to implement them correctly:
- Is this a counter (events), histogram (distribution), or gauge (current value)?
- What labels/dimensions do you want? (e.g., by user tier, by region, by model version)
- Where in the code should it be recorded?

### Step 5.3: Generate the instrumentation code

Based on the user's selections, generate the actual code changes. Write complete, paste-ready code — not pseudocode.

**Guiding rules for what metric type to use:**

| Situation | Type | Reason |
|-----------|------|--------|
| Counting events (requests, errors, jobs) | Counter | Monotonically increasing; use `rate()` in PromQL |
| Measuring durations or sizes | Histogram | Enables percentile queries (`histogram_quantile`) |
| Tracking current state (queue depth, connections) | Gauge | Can go up and down; use directly in PromQL |
| Measuring success rate | Two counters (total + failures) | Ratio = failures / total |

**Guiding rules for spans:**

| Situation | Action |
|-----------|--------|
| Database query | Wrap in a child span; set `db.system`, `db.operation`, `db.table` attributes |
| External HTTP call | Wrap in a child span; set `http.url`, `http.method`, `peer.service` |
| Expensive computation | Wrap in a child span; set domain-specific attributes (model name, input size) |
| Business event | Add a **span event** (not a new span) to the existing request span |
| Error / exception | Call `span.record_exception(exc)` and `span.set_status(StatusCode.ERROR, str(exc))` |

For Python, create a dedicated `metrics.py` module:

```python
# app/metrics.py — all custom Prometheus metrics for <service-name>
#
# Import this module once at startup (in main.py) and use the metric objects
# directly in your route handlers and service functions.
#
# Naming convention: <service>_<noun>_<unit>_total (counters)
#                    <service>_<noun>_<unit>      (histograms, gauges)
from prometheus_client import Counter, Histogram, Gauge

# ---- Counters ----
# Example: orders_created_total — increment when an order is successfully created
ORDERS_CREATED = Counter(
    "<service>_orders_created_total",
    "Number of orders successfully created",
    ["tier"],          # label: customer tier (free, pro, enterprise)
)

PAYMENTS_FAILED = Counter(
    "<service>_payments_failed_total",
    "Number of failed payment attempts",
    ["reason"],        # label: decline_code, network_error, validation_error
)

# ---- Histograms ----
DB_QUERY_DURATION = Histogram(
    "<service>_db_query_duration_seconds",
    "Duration of database queries",
    ["operation", "table"],   # labels: select/insert/update, table name
    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0],
)

INFERENCE_DURATION = Histogram(
    "<service>_inference_duration_seconds",
    "Duration of ML model inference",
    ["model"],
    buckets=[0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0],
)

# ---- Gauges ----
QUEUE_DEPTH = Gauge(
    "<service>_queue_depth",
    "Number of jobs waiting in the processing queue",
)
```

Usage in route handlers:
```python
from .metrics import ORDERS_CREATED, DB_QUERY_DURATION
import time

@app.post("/orders")
def create_order(body: OrderCreate):
    with tracer.start_as_current_span("create-order") as span:
        span.set_attribute("order.tier", body.tier)
        span.set_attribute("order.item_count", len(body.items))

        # Measure DB insert time
        t0 = time.monotonic()
        order = db.insert_order(body)
        DB_QUERY_DURATION.labels(operation="insert", table="orders").observe(
            time.monotonic() - t0
        )

        # Record business event
        ORDERS_CREATED.labels(tier=body.tier).inc()

        # Add a span event for the business moment (different from a span — it's a log within a span)
        span.add_event("order.created", {"order.id": str(order.id)})

        return order
```

For wrapping external calls in a child span:
```python
from opentelemetry import trace
from opentelemetry.trace import StatusCode

tracer = trace.get_tracer("<service>")

def call_payment_provider(order_id: str, amount: int) -> dict:
    with tracer.start_as_current_span("external.stripe") as span:
        span.set_attribute("peer.service", "stripe")
        span.set_attribute("http.method", "POST")
        span.set_attribute("order.id", order_id)
        span.set_attribute("payment.amount_cents", amount)
        try:
            result = stripe.PaymentIntent.create(amount=amount, currency="usd")
            span.set_attribute("payment.intent_id", result.id)
            return result
        except stripe.error.CardError as e:
            span.record_exception(e)
            span.set_status(StatusCode.ERROR, str(e))
            PAYMENTS_FAILED.labels(reason=e.code).inc()
            raise
```

For Node.js, create a `lib/metrics.js` module following the pattern in `references/nodejs-patterns.md`.

### Step 5.4: Add new alert rules for custom metrics

For each business metric the user chose to implement, add corresponding alert rules to `kubernetes/base/<service-name>/alerts.yaml`. Examples:

```yaml
# Business SLOs — add to the existing alerts.yaml under a new group
- name: <service-name>.business
  interval: 60s
  rules:
    # Alert if payment failure rate spikes
    - alert: <ServiceName>HighPaymentFailureRate
      expr: |
        (
          rate(<service>_payments_failed_total[5m])
          /
          rate(http_requests_total{handler="/api/payments"}[5m])
        ) > 0.02
      for: 3m
      labels:
        severity: critical
        service: <service-name>
      annotations:
        summary: "<service-name> payment failure rate above 2%"
        description: "{{ $value | humanizePercentage }} of payment attempts are failing."

    # Alert if inference latency P95 is too high
    - alert: <ServiceName>SlowInference
      expr: |
        histogram_quantile(0.95,
          rate(<service>_inference_duration_seconds_bucket[5m])
        ) > 5.0
      for: 5m
      labels:
        severity: warning
        service: <service-name>
      annotations:
        summary: "<service-name> inference P95 above 5 seconds"
        description: "95th percentile inference time is {{ $value | humanizeDuration }}."
```

Only generate alert rules for metrics the user chose to implement. Match the metric names exactly.

---

## Phase 6: Code Changes Required in the App Repo

After generating all the infra files and the metrics/spans code, list the remaining changes needed in the application repository. Be specific — show the actual code, not just descriptions.

### 6.1 Health endpoints

If missing, show the exact code to add for the detected framework. See `references/python-patterns.md` and `references/nodejs-patterns.md` for ready-to-paste implementations.

Key requirement: the health endpoint path must match what you put in `values.yaml` under `probes.liveness.path` and `probes.readiness.path`.

### 6.2 Structured JSON logging with OTeL trace injection

For Python services, show how to add `services/demo-service/app/logging_config.py` to the app. The key requirement is:
1. JSON output (not plain text)
2. Logs go to stdout
3. `trace_id` and `span_id` are injected from the active OTeL span

For Node.js services, use `pino` with JSON output and `@opentelemetry/api` for span context injection.

### 6.3 OTeL tracing setup

For Python/FastAPI, show how to add `services/demo-service/app/telemetry.py` to the app. Key requirements:
1. `setup_tracing()` called in the FastAPI lifespan handler
2. `OTLP_ENDPOINT` env var controls where traces go (empty = console dev mode)
3. `FastAPIInstrumentor.instrument()` auto-instruments all routes

Required packages to add to `requirements.txt`:
```
opentelemetry-sdk
opentelemetry-exporter-otlp-proto-grpc
opentelemetry-instrumentation-fastapi
```

### 6.4 Prometheus metrics endpoint

For Python/FastAPI, show:
```python
from prometheus_fastapi_instrumentator import Instrumentator
Instrumentator().instrument(app).expose(app, endpoint="/metrics")
```

Add to `requirements.txt`: `prometheus-fastapi-instrumentator`

### 6.5 Dockerfile (if missing or needs improvement)

Generate a production-ready Dockerfile following the pattern in the relevant reference file. Requirements:
- Multi-stage build (builder + runtime stages)
- Non-root user
- Dependency layer cached before source code copy
- Pinned base image tag (never `latest`)

Also generate `.dockerignore`:
```
.git
.github
__pycache__
*.pyc
*.pyo
.env
.env.*
!.env.example
node_modules
.DS_Store
```

---

## After generating everything

Present a checklist of manual steps the user must take **after** adding the generated files to the infra repo:

```
Post-generation checklist (Production):
□ 1. Copy the generated files into the correct paths in ProfJim-Inc/infra
□ 2. Commit and push to main (ArgoCD syncs automatically for Helm+values changes)
□ 3. Apply the ArgoCD Application manually:
     kubectl apply -f argocd/applications/<service-name>.yaml
□ 4. Create the GHCR pull secret in the production namespace (if not already done):
     kubectl create secret docker-registry ghcr-pull-secret \
       -n production \
       --docker-server=ghcr.io \
       --docker-username=<github-username> \
       --docker-password=<github-pat>
□ 5. Create the Slack alertmanager secret (if not already done):
     kubectl create secret generic alertmanager-slack-secret \
       -n production \
       --from-literal=webhook_url=<slack-webhook-url>
□ 6. Create any app-specific Kubernetes Secrets referenced in secretRefs
□ 7. Add the INFRA_DEPLOY_TOKEN secret to the app repo's GitHub settings
□ 8. Add the code changes (health endpoints, logging, OTeL) to the app repo
□ 9. Push a tagged release (e.g., v1.0.0) to trigger the first production deployment
□ 10. Verify in ArgoCD UI that the application syncs successfully
□ 11. Point DNS for <subdomain>.creatium.com to the NodeBalancer IP
      (get it with: kubectl get svc -n ingress-nginx)
```

If staging was selected, also present:

```
Post-generation checklist (Staging):
□ 1. Apply the staging ArgoCD Application to the staging cluster:
     KUBECONFIG=<staging-kubeconfig> kubectl apply -f argocd/applications/<service-name>-stage.yaml
□ 2. Create the GHCR pull secret in the staging namespace:
     KUBECONFIG=<staging-kubeconfig> kubectl create secret docker-registry ghcr-pull-secret \
       -n staging \
       --docker-server=ghcr.io \
       --docker-username=<github-username> \
       --docker-password=<github-pat>
□ 3. Create any app-specific Kubernetes Secrets in the staging cluster
     (same secret names as production, but can use test/sandbox credentials)
□ 4. Push to main — CI will build, push the SHA-tagged image, and update values-stage.yaml
□ 5. Verify staging deployment syncs in ArgoCD
□ 6. Point DNS for <subdomain>.stage.creatium.com to the staging NodeBalancer IP
```

---

## General principles

- **Never invent infrastructure.** This skill targets a specific, real cluster. Don't suggest adding a new service mesh, a different ingress controller, or a different secrets manager. Use what's already deployed.
- **Be specific about paths.** All paths are relative to the root of `ProfJim-Inc/infra`. Use exact paths like `kubernetes/base/<service-name>/values.yaml`, not generic paths.
- **Only override what differs.** The `values.yaml` should only contain keys that differ from `kubernetes/charts/creatium-service/values.yaml` defaults. Don't repeat every default value.
- **Use the demo-service as the canonical reference.** When in doubt about how something should work, look at how `demo-service` does it — it's the reference implementation for the full Creatium observability stack.
- **Flags secrets clearly.** Any value that is sensitive (API keys, passwords, tokens) must go in a Kubernetes Secret via `secretRefs`, never in the ConfigMap (`config:`) section of `values.yaml`.
