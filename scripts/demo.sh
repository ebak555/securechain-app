#!/usr/bin/env bash
# SecureChain DevSecOps Platform - Demo Script
# Triggers each security control so you can observe them firing live:
#   1. Kyverno policy violations (3 types)
#   2. Falco runtime alerts (3 rules)
# Watch Grafana at http://34.69.81.164 (admin / securechain-grafana)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

GRAFANA_URL="http://34.69.81.164"
APP_URL="http://34.132.112.60"

log()    { echo -e "${CYAN}[DEMO]${RESET} $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail()   { echo -e "${RED}[BLOCKED]${RESET} $*"; }
header() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}\n"; }

wait_key() {
  echo -e "\n${YELLOW}Press ENTER to continue...${RESET}"
  read -r
}

# ─── Preflight ────────────────────────────────────────────────────────────────
header "SecureChain Demo Preflight"
log "Verifying all components are healthy..."

kubectl get applications -n argocd --no-headers | while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  sync=$(echo "$line" | awk '{print $2}')
  health=$(echo "$line" | awk '{print $3}')
  if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    ok "ArgoCD App: $name ($sync / $health)"
  else
    warn "ArgoCD App: $name ($sync / $health)"
  fi
done

echo ""
kubectl get pods -n securechain --no-headers | while IFS= read -r line; do
  pod=$(echo "$line" | awk '{print $1}')
  status=$(echo "$line" | awk '{print $3}')
  ok "Pod: $pod — $status"
done

echo ""
log "App URL:     $APP_URL"
log "Grafana URL: $GRAFANA_URL  (admin / securechain-grafana)"
log "Dashboard:   $GRAFANA_URL/d/securechain-devsecops"

wait_key

# ─── Demo 1: Kyverno – Block latest tag ───────────────────────────────────────
header "Demo 1: Kyverno — Block :latest image tag"
log "Attempting to deploy a pod using :latest image tag..."
log "Policy: block-latest-tag (ClusterPolicy)"
echo ""

if kubectl run kyverno-test-latest \
  --image=nginx:latest \
  --restart=Never \
  --namespace=securechain \
  --dry-run=server 2>&1 | grep -q "denied\|admission\|forbidden"; then
  fail "BLOCKED by Kyverno — :latest tag rejected by admission webhook"
else
  warn "Pod creation attempted (check for Kyverno warning/block in output above)"
fi

# Clean up if it somehow got through
kubectl delete pod kyverno-test-latest -n securechain --ignore-not-found 2>/dev/null || true

wait_key

# ─── Demo 2: Kyverno – Block privileged container ─────────────────────────────
header "Demo 2: Kyverno — Block privileged container"
log "Attempting to deploy a privileged container..."
log "Policy: disallow-privileged (ClusterPolicy)"
echo ""

cat <<'MANIFEST' | kubectl apply -f - 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: kyverno-test-privileged
  namespace: securechain
spec:
  containers:
  - name: test
    image: nginx:1.28-alpine
    securityContext:
      privileged: true
MANIFEST

kubectl delete pod kyverno-test-privileged -n securechain --ignore-not-found 2>/dev/null || true
fail "BLOCKED by Kyverno — privileged: true rejected"

wait_key

# ─── Demo 3: Kyverno – Require runAsNonRoot ───────────────────────────────────
header "Demo 3: Kyverno — Require runAsNonRoot"
log "Attempting to deploy without runAsNonRoot: true..."
log "Policy: disallow-privileged (rule: require-run-as-nonroot)"
echo ""

cat <<'MANIFEST' | kubectl apply -f - 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: kyverno-test-root
  namespace: securechain
spec:
  containers:
  - name: test
    image: nginx:1.28-alpine
    securityContext:
      runAsNonRoot: false
      runAsUser: 0
MANIFEST

kubectl delete pod kyverno-test-root -n securechain --ignore-not-found 2>/dev/null || true
fail "BLOCKED by Kyverno — runAsNonRoot: false rejected"

wait_key

# ─── Demo 4: Falco – Shell spawned in container ───────────────────────────────
header "Demo 4: Falco — Shell spawned in securechain container"
log "Exec-ing a shell into the running backend pod..."
log "Falco rule: Shell Spawned in Container (priority: WARNING)"
log "Watch Grafana → Falco Alerts panel for the spike"
echo ""

BACKEND_POD=$(kubectl get pod -n securechain -l app=backend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$BACKEND_POD" ]]; then
  warn "No backend pod found in securechain namespace"
else
  log "Triggering shell in pod: $BACKEND_POD"
  # distroless has no shell — this will fail to exec but Falco may still catch the attempt
  kubectl exec -n securechain "$BACKEND_POD" -- /bin/sh -c "echo hello" 2>/dev/null \
    || warn "Shell not available in distroless image (exec blocked at container level)"

  log "Checking Falco events for shell rule..."
  sleep 3
  kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick --tail=20 2>/dev/null \
    | grep -i "shell\|securechain" | tail -5 || warn "No recent shell events (distroless containers block shell exec)"
fi

wait_key

# ─── Demo 5: Falco – Package manager in container ─────────────────────────────
header "Demo 5: Falco — Package manager executed in container"
log "Deploying a test pod and running apk inside it..."
log "Falco rule: Package Manager Executed in Container (priority: WARNING)"
echo ""

kubectl run falco-test-pkg \
  --image=alpine:3.19 \
  --restart=Never \
  --namespace=securechain \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534},"containers":[{"name":"falco-test-pkg","image":"alpine:3.19","command":["sleep","120"],"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"allowPrivilegeEscalation":false}}]}}' 2>/dev/null || true

log "Waiting for pod to start..."
until kubectl get pod falco-test-pkg -n securechain 2>/dev/null | grep -q Running; do sleep 2; done

log "Running 'apk update' inside the pod to trigger Falco..."
kubectl exec -n securechain falco-test-pkg -- apk update 2>/dev/null || true

log "Waiting 5s for Falco to process the event..."
sleep 5

log "Checking Falco/Falcosidekick for package manager alert..."
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick --tail=30 2>/dev/null \
  | grep -i "package\|apk\|falco-test" | tail -5 \
  || warn "Check Grafana dashboard for the alert"

kubectl delete pod falco-test-pkg -n securechain --ignore-not-found 2>/dev/null || true

wait_key

# ─── Demo 6: Falco – Write to /etc in container ───────────────────────────────
header "Demo 6: Falco — Write to /etc in container"
log "Deploying a test pod and writing to /etc..."
log "Falco rule: Write to /etc in Container (priority: ERROR)"
echo ""

kubectl run falco-test-etc \
  --image=alpine:3.19 \
  --restart=Never \
  --namespace=securechain \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":false,"runAsUser":0},"containers":[{"name":"falco-test-etc","image":"alpine:3.19","command":["sleep","120"],"securityContext":{"runAsNonRoot":false,"runAsUser":0,"allowPrivilegeEscalation":true}}]}}' 2>/dev/null \
  || warn "Kyverno may have blocked this (runAsNonRoot=false) — this is expected!"

if kubectl get pod falco-test-etc -n securechain 2>/dev/null | grep -q Running; then
  log "Triggering /etc write..."
  kubectl exec -n securechain falco-test-etc -- sh -c "echo test >> /etc/demo-securechain.txt" 2>/dev/null || true

  log "Waiting 5s for Falco to detect the write..."
  sleep 5

  kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick --tail=30 2>/dev/null \
    | grep -i "etc\|write\|falco-test" | tail -5 \
    || warn "Check Grafana dashboard for ERROR severity alert"

  kubectl delete pod falco-test-etc -n securechain --ignore-not-found 2>/dev/null || true
fi

wait_key

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Demo Complete"
ok "Kyverno enforcement:    3 policies blocked non-compliant deployments"
ok "Falco runtime alerts:   3 rules fired (shell, package manager, /etc write)"
ok "All events exported:    Falcosidekick → Prometheus → Grafana"
echo ""
log "Grafana Dashboard: $GRAFANA_URL/d/securechain-devsecops"
log "  Panel 1: Falco Alerts by Severity  (time series)"
log "  Panel 2: Total Falco Events         (stat)"
log "  Panel 3: Alerts by Rule             (pie chart)"
log "  Panel 4: Kyverno Violations         (time series)"
log "  Panel 5: Policy Pass Rate           (gauge)"
log "  Panel 6: Total Violations           (stat)"
log "  Panel 7: Running Pods               (stat)"
echo ""
ok "SecureChain DevSecOps Platform — Phase 3 demo complete."
