#!/usr/bin/env bash
# Load test: starts a load pod, records scale-up and scale-down timings in loadtest/timing.log
set -uo pipefail
NS=inventory; HPA=inventory-hpa
LOG="$(dirname "$0")/timing.log"; : > "$LOG"
log()  { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG"; }
desired() { kubectl -n $NS get deploy inventory-service -o jsonpath='{.spec.replicas}'; }
cpu()  { kubectl -n $NS get hpa $HPA -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}'; }
snap() { log "replicas=$(desired) cpu=$(cpu)%"; }
trap 'kubectl -n $NS delete pod load-gen --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

log "BASELINE"; snap
log "LOAD START (6 parallel request loops)"
kubectl -n $NS run load-gen --image=busybox:1.36 --restart=Never -- /bin/sh -c \
  'for i in 1 2 3 4 5 6; do (while true; do wget -q -O- http://inventory-service/cpu >/dev/null 2>&1; done) & done; wait'
T0=$(date +%s); UP_START=""
while true; do
  r=$(desired); now=$(( $(date +%s) - T0 ))
  if [ -z "$UP_START" ] && [ "$r" -gt 3 ]; then UP_START=$now; log "SCALE-UP began at +${now}s (replicas=$r)"; fi
  if [ "$r" -ge 10 ]; then log "MAX reached: 10 replicas at +${now}s"; break; fi
  if [ "$now" -gt 600 ]; then log "TIMEOUT waiting for scale-up"; break; fi
  snap; sleep 5
done
log "holding load for 60s at max"; sleep 60; snap

log "LOAD STOP"
kubectl -n $NS delete pod load-gen --wait=false >/dev/null 2>&1
T1=$(date +%s); DOWN_START=""
while true; do
  r=$(desired); now=$(( $(date +%s) - T1 ))
  if [ -z "$DOWN_START" ] && [ "$r" -lt 10 ]; then DOWN_START=$now; log "SCALE-DOWN began at +${now}s (replicas=$r)"; fi
  if [ "$r" -le 3 ]; then log "BACK TO MIN: 3 replicas at +${now}s"; break; fi
  if [ "$now" -gt 900 ]; then log "TIMEOUT waiting for scale-down"; break; fi
  snap; sleep 5
done
log "DONE"
