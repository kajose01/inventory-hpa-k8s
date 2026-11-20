# Inventory Service: Kubernetes HPA

A small Node.js inventory microservice deployed on Kubernetes with a Horizontal Pod Autoscaler (min 3, max 10, target 50% CPU), plus a repeatable load test that records scale-up and scale-down timings.

## 1. Problem Statement

XYZ Corporation's inventory service must stay responsive when demand spikes and must not waste resources when demand drops. The task is to:

- run the inventory service with 3 replicas to start,
- autoscale it between 3 and 10 replicas when average CPU passes 50%,
- prove the behaviour with a load test, with timings for scale-up and scale-down,
- document the results in a short report.

## 2. Repository Layout

The service exposes `GET /health`, `GET /items`, `GET /items/:id`, and `GET /cpu`. `/cpu` hashes data for about 100 ms to create real CPU load.

## 3. Steps to Build and Run

Prerequisites: a Kubernetes cluster with metrics-server (k3s includes it), `kubectl`, and Docker.

```bash
# 1. Build and push the image
docker build -t kaj1/inventory-service:1.0 app/
docker push kaj1/inventory-service:1.0

# 2. Deploy
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/
kubectl -n inventory rollout status deploy/inventory-service

# 3. Verify (HPA shows <unknown> for the first 30-60 s)
kubectl -n inventory get pods,svc,hpa

# 4. Run the load test (about 3 minutes)
./loadtest/run.sh
cat loadtest/timing.log
```

The load test starts a busybox pod that runs 6 parallel `wget` loops against `/cpu`. It records the replica count and CPU every 5 seconds, holds the load for 60 seconds once 10 replicas are reached, then stops the load and waits for the scale-down. No external load tool is needed.

## 4. Load Test Report

Results come from `loadtest/timing.log` (run on 2026-10-15, single-node k3s):

| Event | Time | Offset |
|---|---|---|
| Baseline: 3 replicas, 1% CPU | 21:28:20 | |
| Load start (6 request loops) | 21:28:20 | +0 s |
| Scale-up began: 3 to 7 replicas | 21:28:41 | +21 s |
| Max reached: 10 replicas | 21:28:57 | +37 s |
| Peak CPU | 21:30:08 | 166% of request |
| Load stop | 21:29:57 | |
| CPU back below target (1%) | 21:31:11 | +74 s after stop |
| Scale-down: 10 to 3 replicas | 21:31:57 | +120 s after stop |

**Scale-up:** the HPA reacted 21 s after the load began and reached the maximum in 37 s. The jump from 3 to 7 replicas matches the default scale-up limit of 4 pods per 15 s. The rest followed in the next cycle.

**Scale-down:** CPU stayed high for about 53 s after the load pod was deleted, because the pod needs its termination grace period and metrics-server lags. After CPU fell, the 60 s stabilization window held the replicas at 10 before they dropped to 3 in one step. The service stayed at 3 replicas afterwards.

CPU utilization above 100% is expected: it is measured against the CPU *request* (100m), not the limit (250m).

## 5. Optimization Techniques Used

- **Small image:** `node:20-alpine`, only `package.json` and `server.js` copied, `.dockerignore` excludes junk.
- **Non-root, locked-down container:** `runAsNonRoot`, `allowPrivilegeEscalation: false`.
- **Resource requests and limits:** CPU request 100m / limit 250m and memory 64Mi / 128Mi. The request is what makes percentage-based HPA possible, and the limits stop one pod from starving the node.
- **Health probes:** a readiness probe keeps new pods out of the Service until ready, and a liveness probe restarts hung pods.
- **HPA tuning:** `autoscaling/v2`, 50% CPU target, min 3 / max 10, and a 60 s `scaleDown` stabilization window (default 300 s) so capacity is released faster without flapping.
- **Isolated namespace:** `inventory` has no service-mesh sidecars, so CPU measurements reflect only the application.
- **Load test as code:** `loadtest/run.sh` is repeatable and needs no extra tools.

## 6. Challenges Faced and Solutions

| Challenge | Solution |
|---|---|
| No load tool (`hey`, `ab`, `wrk`) on the server | Ran the load from an in-cluster busybox pod with parallel `wget` loops, so the test is repeatable anywhere. |
| HPA showed `cpu: <unknown>` right after deploy | metrics-server needs 30-60 s to collect data, and the Deployment must define CPU requests. Waited, then confirmed `1%/50%`. |
| Scale-down looked slow after the load stopped | CPU stayed high while the load pod terminated and metrics caught up, then the stabilization window applied. Documented this and shortened the window to 60 s. |
| CPU readings above 100% looked wrong | Utilization is relative to the 100m request, not the limit. Explained in the report. |

## Measured results (loadtest/runs/run-1..3)
Three valid runs on a single-node k3s cluster (6 parallel request loops against /cpu, 3 to 10 replicas, 50% CPU target).

| Run | Scale-up began | Desired = 10 | All 10 Ready | Scale-down began | Back to 3 |
|---|---|---|---|---|---|
| 1 | +38 s | +55 s | +60 s | +112 s | +128 s |
| 2 | +44 s | +55 s | +67 s | +128 s | +128 s |
| 3 | +44 s | +61 s | +67 s | +112 s | +128 s |

Scale-up offsets are measured from load start, scale-down offsets from load stop.

Observations:
- Scale-up began 38-44 s after load start; 10 replicas were desired by 55-61 s.
- Desired and ready replicas differed briefly (for example 7 ready while 10 were desired in run 2), so desired-replica timing alone overstates available capacity.
- After load stopped, CPU stayed above 100% for roughly 65-70 s before dropping.
- The Deployment returned to 3 replicas 128 s after load stop in all three runs.
- At 10 replicas CPU was still about 125-135% of the request, so maxReplicas (not scaling speed) limited capacity under this load.

Interpretation (not isolated by this data): the delayed CPU drop after load stopped may be due to load pod termination or metrics-server lag; this test did not separate the causes. Timings are from one environment and are not guaranteed elsewhere.

## Excluded runs
Several runs were excluded (stale load pod, overlapping runs, a run interrupted by pkill, a failed precondition). They are kept in loadtest/runs/excluded/ for transparency.

## Note on scope
The review PDF lists the repository postgres-statefulset-k8s and contains sections on PostgreSQL storage. This project is the Inventory HPA service in inventory-hpa-k8s; those sections belong to a different assignment.
