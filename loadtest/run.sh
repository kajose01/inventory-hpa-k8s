#!/usr/bin/env bash
# Load test: starts a load pod and records scale-up/scale-down timings.
# Usage: ./loadtest/run.sh [run-number]   (outputs go to loadtest/runs/run-N/)
set -euo pipefail
NS=inventory; HPA=inventory-hpa; DEP=inventory-service
RUN="${1:-1}"
DIR="$(cd "$(dirname "$0")" && pwd)/runs/run-$RUN"
mkdir -p "$DIR"
LOG="$DIR/timing.log"; : > "$LOG"
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }
g()   { kubectl -n $NS get deploy $DEP -o jsonpath="$1" 2>/dev/null || true; }
desired()   { g '{.spec.replicas}'; }
ready()     { v=$(g '{.status.readyReplicas}'); echo "${v:-0}"; }
available() { v=$(g '{.status.availableReplicas}'); echo "${v:-0}"; }
cpu() { v=$(kubectl -n $NS get hpa $HPA -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true); echo "${v:-n/a}"; }
snap() { log "desired=$(desired) ready=$(ready) available=$(available) cpu=$(cpu)%"; }
FAILED=0
cleanup() {
  kubectl -n $NS delete pod load-gen --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n $NS get hpa $HPA > "$DIR/hpa-final.txt" 2>&1 || true
  kubectl -n $NS describe hpa $HPA > "$DIR/hpa-describe.txt" 2>&1 || true
  kubectl -n $NS get pods -o wide > "$DIR/pods-final.txt" 2>&1 || true
  kubectl -n $NS get events --sort-by=.lastTimestamp > "$DIR/events.txt" 2>&1 || true
}
trap cleanup EXIT

# Preconditions: stable at minimum replicas and metrics available
kubectl -n $NS delete pod load-gen --ignore-not-found --wait=true >/dev/null
kubectl -n $NS rollout status deploy/$DEP --timeout=120s
for _ in $(seq 1 60); do   # wait up to ~5 min for a quiet baseline
  c=$(cpu); c=${c//n\/a/100}
  [ "$(desired)" -eq 3 ] && [ "$(ready)" -eq 3 ] && [ "$c" -lt 10 ] && break
  sleep 5
done
[ "$(desired)" -eq 3 ] && [ "$(ready)" -eq 3 ] && [ "$c" -lt 10 ] || { log "FAIL: no quiet baseline (desired=$(desired) ready=$(ready) cpu=${c}%)"; exit 1; }

log "BASELINE"; snap
kubectl -n $NS delete pod load-gen --ignore-not-found >/dev/null
log "LOAD START (6 parallel request loops)"
kubectl -n $NS run load-gen --image=busybox:1.36 --restart=Never -- /bin/sh -c \
  'for i in 1 2 3 4 5 6; do (while true; do wget -q -O- http://inventory-service/cpu >/dev/null 2>&1; done) & done; wait'
kubectl -n $NS wait --for=condition=Ready pod/load-gen --timeout=90s
log "load-gen pod Ready"

T0=$(date +%s); UP_START=""; MAXR=""; ALLREADY=""
while true; do
  r=$(desired); rd=$(ready); now=$(( $(date +%s) - T0 ))
  [ -z "$UP_START" ] && [ "$r" -gt 3 ] && { UP_START=$now; log "SCALE-UP began at +${now}s (desired=$r)"; }
  [ -z "$MAXR" ] && [ "$r" -ge 10 ] && { MAXR=$now; log "DESIRED reached 10 at +${now}s"; }
  if [ "$rd" -ge 10 ]; then ALLREADY=$now; log "ALL 10 READY at +${now}s"; break; fi
  if [ "$now" -gt 600 ]; then log "FAIL: TIMEOUT waiting for scale-up"; FAILED=1; break; fi
  snap; sleep 5
done
if [ "$FAILED" -eq 0 ]; then
  log "holding load for 60s at max"; sleep 60; snap
  log "LOAD STOP"
  kubectl -n $NS delete pod load-gen --wait=false >/dev/null
  T1=$(date +%s); DOWN_START=""
  while true; do
    r=$(desired); now=$(( $(date +%s) - T1 ))
    [ -z "$DOWN_START" ] && [ "$r" -lt 10 ] && { DOWN_START=$now; log "SCALE-DOWN began at +${now}s (desired=$r)"; }
    if [ "$r" -le 3 ]; then log "BACK TO MIN: 3 replicas at +${now}s"; break; fi
    if [ "$now" -gt 900 ]; then log "FAIL: TIMEOUT waiting for scale-down"; FAILED=1; break; fi
    snap; sleep 5
  done
fi
if [ "$FAILED" -eq 0 ]; then log "RESULT: PASS"; else log "RESULT: FAIL"; exit 1; fi
