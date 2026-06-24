# SecureChain DevSecOps Platform

A production-grade Secure Software Supply Chain platform deployed on Google Kubernetes Engine (GKE).
Covers the full DevSecOps lifecycle: code scanning → image signing → policy enforcement → GitOps deployment → runtime threat detection → observability.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    DEVELOPER WORKSTATION (WSL2)                   │
│          gcloud  │  kubectl  │  trivy  │  cosign  │  gitleaks    │
└──────────────────────────────┬───────────────────────────────────┘
                               │  git push
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│                         GITHUB                                    │
│                                                                  │
│   securechain-app                  securechain-gitops            │
│   (source code + CI workflows)     (K8s manifests + image tags)  │
│             │                                 ▲                  │
│             │ triggers                        │ pipeline writes  │
│             ▼                                 │ new image tag    │
│   ┌─────────────────────────────────────────┐ │                  │
│   │         GITHUB ACTIONS PIPELINE         │ │                  │
│   │                                         │ │                  │
│   │  Job 1 — Code Security                  │ │                  │
│   │  ├── Gitleaks  (secrets in source code) │ │                  │
│   │  └── Trivy fs  (CVEs in dependencies)   │ │                  │
│   │              │ pass                      │ │                  │
│   │  Job 2 — Container Security             │ │                  │
│   │  ├── Hadolint  (Dockerfile lint)        │ │                  │
│   │  ├── docker build                       │ │                  │
│   │  ├── Trivy image (CVEs in image)        │ │                  │
│   │  ├── Cosign sign (keyless via OIDC)     │ │                  │
│   │  ├── Syft SBOM  (what is in the image)  │ │                  │
│   │  └── Push → ghcr.io                    │ │                  │
│   │              │ pass                      │ │                  │
│   │  Job 3 — GitOps Update                  │─┘                  │
│   │  └── Update image tag in gitops repo    │                    │
│   └─────────────────────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────┘
                               │
                        ArgoCD watches
                        securechain-gitops
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────┐
│          GKE CLUSTER  —  us-central1-a  —  e2-standard-2         │
│                     1 node │ 2 vCPU │ 8GB RAM                    │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  ARGOCD                                                   │   │
│  │  Watches securechain-gitops every 3 minutes               │   │
│  │  New image tag committed → rolling update triggered       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                             │                                    │
│                             ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  KYVERNO  —  Admission Controller                         │   │
│  │  Every kubectl apply is intercepted here                  │   │
│  │                                                           │   │
│  │  Policy 1: block-latest-tag         reject :latest tag   │   │
│  │  Policy 2: require-limits           reject missing CPU/RAM│   │
│  │  Policy 3: disallow-privileged      reject root pods      │   │
│  │  Policy 4: require-labels           reject missing labels  │   │
│  │  Policy 5: verify-image-signature   reject unsigned images│   │
│  └──────────────────────────────────────────────────────────┘   │
│                             │                                    │
│                             ▼                                    │
│  ┌─────────────────────┐  ┌───────────────────────────────────┐ │
│  │      frontend        │  │             backend               │ │
│  │   nginx (port 80)    │─▶│       Go REST API (port 8080)    │ │
│  │   GKE LoadBalancer   │  │       ClusterIP only              │ │
│  │   → public URL       │  │       Vault secrets injected      │ │
│  └─────────────────────┘  └───────────────────────────────────┘ │
│          NetworkPolicy: frontend→backend only, deny all else     │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  FALCO  —  Runtime Threat Detection (eBPF)                │   │
│  │  Monitors every syscall on every node                     │   │
│  │  Detects: shell in container, /etc writes,                │   │
│  │           package installs, suspicious outbound           │   │
│  │  Falcosidekick → Grafana webhook alert                   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  PROMETHEUS + GRAFANA                                     │   │
│  │  Scrapes: Kyverno violations, Falco alerts, cluster health│   │
│  │  Custom dashboard: Security Posture                       │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## Technology Stack

| Layer | Tool | Purpose |
|---|---|---|
| Cloud | GKE (Google Kubernetes Engine) | Managed Kubernetes cluster |
| Container Registry | ghcr.io (GitHub Container Registry) | Store signed images |
| CI/CD | GitHub Actions | Automated security pipeline |
| GitOps | ArgoCD | Deploy from Git, zero manual kubectl |
| Secrets Scanning | Gitleaks | Detect secrets in source code |
| SAST / SCA | Trivy | Scan code and images for CVEs |
| Dockerfile Lint | Hadolint | Enforce Dockerfile best practices |
| Image Signing | Cosign (keyless OIDC) | Sign images via Sigstore |
| SBOM | Syft | Generate Software Bill of Materials |
| Admission Control | Kyverno | Policy-as-code enforcement |
| Runtime Security | Falco (eBPF) | Detect threats at runtime |
| Alerting | Falcosidekick | Route Falco events to dashboards |
| Metrics | Prometheus | Scrape security and cluster metrics |
| Dashboards | Grafana | Visualise security posture |
| Network Security | Kubernetes NetworkPolicy | Microsegmentation between services |

---

## Repository Structure

```
devsecops-prod/
│
├── securechain-app/                   Source code + CI workflows
│   ├── .github/workflows/
│   │   ├── 01-code-scan.yml          Gitleaks + Trivy fs
│   │   ├── 02-image-build.yml        Build + Trivy + Cosign + Syft + Push
│   │   └── 03-gitops-update.yml      Update image tag in securechain-gitops
│   ├── app/
│   │   ├── frontend/                 Nginx + dashboard HTML
│   │   │   └── Dockerfile
│   │   └── backend/                  Go REST API
│   │       ├── main.go
│   │       └── Dockerfile
│   └── scripts/
│       └── demo.sh                   Interview demo script
│
└── securechain-gitops/                K8s manifests (ArgoCD watches this)
    ├── argocd/
    │   └── application.yaml          ArgoCD Application CRD
    ├── app/
    │   ├── namespace.yaml
    │   ├── frontend/
    │   │   ├── deployment.yaml
    │   │   └── service.yaml
    │   ├── backend/
    │   │   ├── deployment.yaml
    │   │   └── service.yaml
    │   └── network-policies/
    │       ├── default-deny-all.yaml
    │       └── allow-frontend-to-backend.yaml
    └── security/
        └── kyverno/
            ├── block-latest-tag.yaml
            ├── require-limits.yaml
            ├── disallow-privileged.yaml
            ├── require-labels.yaml
            └── verify-image-signature.yaml
```

---

## Implementation Phases

### Phase 1 — GKE Cluster + CI Pipeline  `Day 1`

**Objective:** Push code to GitHub and have the full security pipeline run automatically, producing a signed image in ghcr.io.

**Steps:**
1. Install gcloud CLI and authenticate with Google Cloud
2. Create GCP project `securechain-devsecops` and enable GKE API
3. Provision GKE cluster: 1 node, e2-standard-2, us-central1-a
4. Configure kubeconfig locally and confirm `kubectl get nodes` shows Ready
5. Initialise `securechain-app` and `securechain-gitops` local repos
6. Write GitHub Actions workflow `01-code-scan.yml`:
   - Gitleaks scans every file for secret patterns
   - Trivy scans filesystem for dependency CVEs
   - Pipeline fails if CRITICAL findings exist
7. Write GitHub Actions workflow `02-image-build.yml`:
   - Hadolint validates the Dockerfile
   - Docker builds the image
   - Trivy scans the built image
   - Cosign signs the image using keyless signing (GitHub OIDC — no keys stored)
   - Syft generates an SBOM and attaches it as a Cosign attestation
   - Image pushed to ghcr.io
8. Write GitHub Actions workflow `03-gitops-update.yml`:
   - Checks out securechain-gitops
   - Updates the image tag in the deployment manifest
   - Commits and pushes — ArgoCD picks this up automatically

**Checkpoint:** Push a commit → all 3 workflows run green → signed image visible in GitHub Packages

---

### Phase 2 — Admission Control + Sample App  `Day 2`

**Objective:** Deploy the sample app end-to-end through ArgoCD, with Kyverno blocking every policy violation before pods run.

**Steps:**
1. Install ArgoCD on GKE and expose the UI via LoadBalancer
2. Connect ArgoCD to the `securechain-gitops` repo
3. Install Kyverno via Helm
4. Write and apply each Kyverno policy — after each one, deliberately violate it to see the rejection message:
   - `block-latest-tag`: run `kubectl run test --image=nginx:latest` → blocked
   - `require-limits`: deploy a pod with no resources set → blocked
   - `disallow-privileged`: deploy with `privileged: true` → blocked
   - `require-labels`: deploy with no labels → blocked
   - `verify-image-signature`: deploy an unsigned image → blocked
5. Build the two-tier sample application:
   - **Backend**: Go HTTP server with `/health` and `/api/status` endpoints
   - **Frontend**: Nginx serving a dashboard that calls the backend and shows pipeline metadata
6. Write K8s manifests for both services — all policies satisfied
7. Write NetworkPolicy manifests:
   - `default-deny-all`: deny all ingress and egress in the app namespace
   - `allow-frontend-to-backend`: frontend can reach backend on port 8080 only
   - `allow-dns`: egress to kube-dns on port 53 (without this nothing resolves)
8. Commit manifests to `securechain-gitops` — ArgoCD deploys the app
9. Verify the frontend is reachable at the GKE LoadBalancer public IP

**Checkpoint:** Push a bad manifest → Kyverno blocks it. Push the correct app → ArgoCD deploys → app accessible at a public URL.

---

### Phase 3 — Runtime Security + Observability  `Day 3`

**Objective:** Detect threats the moment they happen and surface all security signals in a single Grafana dashboard.

**Steps:**
1. Install Falco on GKE using the eBPF driver (required for managed GKE nodes):
   ```
   driver.kind=ebpf
   ```
2. Install Falcosidekick alongside Falco to route alerts
3. Write 3 custom Falco rules on top of the default ruleset:
   - Shell spawned inside any app container
   - Package manager (apt, pip, yum) run inside a container
   - Write operation to /etc inside a container
4. Test each rule: `kubectl exec -it <pod> -- /bin/sh` should trigger an alert within 3 seconds
5. Install kube-prometheus-stack via Helm with minimal resource values (alertmanager disabled)
6. Confirm Prometheus is scraping:
   - Kyverno policy violation metrics
   - Falco alert metrics via Falcosidekick Prometheus exporter
   - Standard cluster metrics
7. Build one custom Grafana dashboard with 4 panels:
   - Kyverno policy violations by policy name (last 24h)
   - Falco alerts by severity (last 1h)
   - Policy-compliant pods as a percentage of total running pods
   - ArgoCD deployment count (last 7 days)
8. Wire Falcosidekick to send events to the Grafana webhook datasource for real-time alerts
9. Write `scripts/demo.sh` — a script that triggers each violation type and shows the result
10. Delete the GKE cluster after project is complete:
    ```
    gcloud container clusters delete securechain --zone us-central1-a
    gcloud projects delete securechain-devsecops
    ```

**Checkpoint:** Run `demo.sh` → violations fire → Kyverno blocks → Falco alerts → Grafana dashboard updates live.

---

## GKE Cluster Details

| Setting | Value |
|---|---|
| Project | securechain-devsecops |
| Cluster name | securechain |
| Zone | us-central1-a |
| Node count | 1 |
| Machine type | e2-standard-2 |
| vCPU | 2 |
| RAM | 8GB |
| Disk | 50GB pd-balanced |
| Estimated cost | ~$5 from $300 credit (3 days) |

---

## Resume Description

> **SecureChain DevSecOps Platform** — Built a production-grade secure software supply chain on GKE. Implemented a GitHub Actions pipeline with automated secret scanning (Gitleaks), vulnerability scanning (Trivy), image signing (Cosign/Sigstore), and SBOM attestation (Syft). Enforced policy-as-code via Kyverno admission control blocking unsigned, misconfigured, and unapproved workloads. Deployed runtime threat detection with Falco eBPF. Delivered zero-touch GitOps deployments through ArgoCD. Visualised security posture in custom Grafana dashboards.

---

## Cleanup

```bash
gcloud container clusters delete securechain --zone us-central1-a
gcloud projects delete securechain-devsecops
```
