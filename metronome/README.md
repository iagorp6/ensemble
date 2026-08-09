# `metronome` — keeping time

> *The metronome is what tells you the tempo has slipped, before the audience notices.*

Layer 6 of [ensemble](../README.md). Prometheus, Grafana, Loki, Alertmanager
and Grafana Alloy on the K3s cluster — sized to fit what's left of 12 GB.

---

## This layer is mostly subtraction

The interesting work here isn't installing four tools. It's deciding what to
turn **off**.

Both charts default to configurations built for clusters much larger than this
one, and on 2 OCPU / 12 GB their defaults aren't a tuning problem — several of
them are a non-starter:

| Default | What it does here |
|---|---|
| `loki.deploymentMode: SimpleScalable` | **12 pods** (3 backend, 3 read, 3 write, 2 memcached, 1 nginx) |
| `loki.storage.type: s3` | Wants object storage that doesn't exist. Loki won't start |
| `loki.auth_enabled: true` | Every query needs an `X-Scope-OrgID` header. Forget it and Grafana shows **empty results, not an error** |
| `prometheus.retentionSize: ''` | Unlimited. Prometheus fills the disk and stops accepting writes |
| `prometheus.resources: {}` | Unlimited. Prometheus OOM-kills its neighbours |
| `prometheus.storageSpec: {}` | `emptyDir` — **all history lost on every pod restart** |
| `kubeControllerManager/Scheduler/Proxy/Etcd: true` | Four permanently-down scrape targets on K3s (see below) |
| 34 default rule groups | Includes etcd and kube-proxy alerts for components that don't exist |

Knowing which mode to pick, and being able to say what you gave up, is more of
the job than knowing how to run the big one.

### What it actually costs, measured

Rendered from the real charts with these values and totalled:

| Workload | CPU req | Mem req | Mem limit |
|---|---:|---:|---:|
| Prometheus | 100m | 512Mi | 1500Mi |
| Loki (single binary) | 100m | 256Mi | 640Mi |
| Grafana + 2 sidecars | 70m | 192Mi | 384Mi |
| Prometheus Operator | 25m | 64Mi | 192Mi |
| Alertmanager | 25m | 64Mi | 128Mi |
| kube-state-metrics | 20m | 64Mi | 128Mi |
| node-exporter | 20m | 32Mi | 64Mi |
| Alloy + reloader | 60m | 178Mi | 256Mi |
| **metronome total** | **420m** | **1362Mi** | **3292Mi** |

Against the node, with ArgoCD and the app already on it:

```
TOTAL scheduled (requests)   1520m   3474Mi    = 76% CPU, 28% RAM
TOTAL worst case (limits)            6108Mi    = 48% RAM
node (Always Free, 24/7)     2000m  12595Mi
```

CPU is the binding constraint, not memory — 76% of requests committed. That's
why `metronome` uses `60s` scrape and evaluation intervals rather than the
chart's `30s`.

---

## The K3s trap

Same shape as layer 2's iptables problem: **the defaults are correct for a
normal cluster and quietly wrong here.**

K3s runs the API server, controller-manager and scheduler inside **one
process**, and a single node uses SQLite rather than etcd. So there are no
`kube-controller-manager` or `kube-scheduler` pods to scrape, and no etcd at
all. The chart's default ServiceMonitors point at endpoints that were never
created.

Leave them on and you get four permanently-down targets plus a steady drip of
`KubeControllerManagerDown` / `KubeSchedulerDown` / `etcd*` alerts firing
forever — which is **worse than no monitoring**, because a dashboard that's
always red teaches you to stop looking at it.

Verified in the render: no ServiceMonitor for any of the four, and 27 rule
groups remain of the chart's 34.

---

## Decisions worth defending

**Both retention limits, and the second one is the real one.** `retention: 7d`
is a promise about time, not disk — how much data that is depends on how many
series get scraped, which changes every deploy. A cardinality spike fills the
volume and Prometheus stops accepting writes, so monitoring dies exactly when
you need it. `retentionSize: 8GB` against a 10Gi volume is the actual safety
net, leaving room for the WAL and compaction.

Loki has the identical trap: `retention_period` is advisory unless
`compactor.retention_enabled: true` tells something to actually delete.

**`60s` scrape interval halves the cost, and the loss is real.** Roughly half
the samples means roughly half the memory and disk. What you give up is
resolution between 30 and 60 seconds — an outage shorter than a minute can be
missed entirely. Acceptable when alert thresholds are measured in minutes; not
acceptable on a payments system.

**No CPU limits, memory limits everywhere.** Same reasoning as layers 3 and 4: a
CPU limit throttles via the kernel's CFS quota even on an idle node, and
Prometheus is bursty — compaction and rule evaluation want whatever's spare.
Memory is incompressible, so it gets a hard ceiling.

**Health-check logs are dropped at the agent.** Two probes per pod every ten
seconds, forever, all saying nothing happened — the single largest source of log
volume on a cluster that's working. Dropping them in Alloy is the difference
between a 7-day retention window and a 2-day one on the same disk.

**Log labels are deliberately few.** Every distinct label combination is a
separate Loki stream with its own index entry and its own open chunk in memory.
`namespace`, `app`, `pod`, `container`, `level` — and everything else stays in
the line, searchable with LogQL filters. That trades cheap writes for slightly
more expensive reads, which is the whole design of Loki and why it runs in
640 MB where Elasticsearch would not. Same discipline as the metric-cardinality
guard in [score](../score/main_test.go).

**Alloy, not Promtail.** Promtail is what nearly every Loki tutorial still uses.
It reached **end of life on 2 March 2026** — no updates, no security fixes.
Grafana's docs: *"If you are currently using Promtail, you must migrate to Alloy
or another supported client."* Checking whether a component is still alive
before adopting it is a small habit that ages a platform well.

**ServiceMonitors, not scrape annotations.** Layer 4 put `prometheus.io/scrape`
annotations on the app — the classic approach, and the right one when you run
Prometheus from a config file. The Operator inverts it: targets become API
objects that are reviewable in a diff and *validated* on apply. A typo'd
annotation is silently ignored and the target simply never appears. The
annotations are left in place as documentation of intent.

**Sync waves, because CRDs have to exist first.** The four Applications deploy
in order — stack (0) → Loki (1) → Alloy (2) → rules (3). Without waves,
ArgoCD applies everything at once and the ServiceMonitor and PrometheusRule are
rejected with *"no matches for kind"*. That failure is self-correcting, which is
exactly why it's worth fixing: an eventually-consistent deploy that spends five
minutes red teaches people to ignore red.

**`prune: false` on the Prometheus stack only.** It owns CRDs, and deleting a
CRD deletes every object of that type **cluster-wide** — every ServiceMonitor and
PrometheusRule in every namespace, including ones this Application never
created. A momentary rendering glitch shouldn't be able to do that. The cost is
that a removed component lingers until deleted by hand. Everything else in the
platform prunes.

**`ServerSideApply` isn't optional here.** The Prometheus and Alertmanager CRDs
exceed the 262144-byte annotation limit client-side apply uses to store its
last-applied state. Without it the sync fails outright with
`metadata.annotations: Too long`.

---

## One alert

kube-prometheus-stack already ships ~27 rule groups about the cluster. What was
missing was an alert about the **application**, written against metrics the
application chose to expose.

```promql
(
  sum(rate(overture_requests_total{job="overture",status="5xx"}[5m]))
  /
  sum(rate(overture_requests_total{job="overture"}[5m]))
) > 0.05
```

`for: 5m`. Four decisions in six lines:

- **Ratio, not count.** A count threshold is deafening under load and silent at
  3am when three requests out of three fail. A ratio is traffic-independent, so
  one threshold works at every hour.
- **5xx only.** 4xx is the client being wrong — a scanner probing `/private`, a
  stale bookmark. Paging someone because a stranger sent a bad request is how
  alert fatigue starts.
- **`for: 5m` is the most important line.** Without it, one bad scrape during a
  rolling update pages someone. The cost is 5 minutes of delay on a real
  outage; the value is that a deploy blip resolves itself.
- **Divide-by-zero is benign.** With no traffic both sides are 0, and `NaN >
  0.05` is false. Idle periods can't fire it — which also means this alert says
  nothing when the app is receiving nothing. That case belongs to `TargetDown`,
  which the chart already provides.

Resisting the urge to add ten more is the point. The bar for a second one is
*"what would I do differently at 3am if this fired?"*

---

## Running it

Nothing to run. Commit and push — `downbeat` picks up the four Applications and
the waves handle ordering.

```bash
kubectl -n argocd get applications
kubectl -n metronome get pods
```

Reach the UIs by tunnel, same as ArgoCD (no ingress, deliberately):

```bash
kubectl -n metronome port-forward svc/metronome-grafana 3000:80
# http://localhost:3000 — admin / ensemble

kubectl -n metronome port-forward svc/metronome-kube-prometheus-prometheus 9090:9090
kubectl -n metronome port-forward svc/metronome-kube-prometheus-alertmanager 9093:9093
```

Check the app is being scraped, and that nothing is permanently down:

```
# in Prometheus → Status → Targets
up{job="overture"}        should be 1
```

## Proving the alert fires

The demonstration that ties three layers together, and it's the failure story
this repo has been missing:

1. Break `overture` deliberately — a commit that returns 500 from `/`.
2. `score` builds it, `cue` writes the digest, ArgoCD deploys it.
3. Within ~6 minutes `OvertureHighErrorRate` fires and Alertmanager posts to
   `maestro`.
4. **Roll back with `git revert`.** The image is pinned by digest, so this
   restores the exact bytes that were working — not a rebuild that resembles
   them.

That single sequence exercises layers 3, 4 and 6 at once, and produces the
before/after evidence that a screenshot of a green dashboard never will.

---

## Verified

Rendered from the real charts (kube-prometheus-stack 88.2.0, loki 7.2.0, alloy
1.11.1) and asserted against, not assumed:

- No ServiceMonitor for controller-manager, scheduler, kube-proxy or etcd; 27
  rule groups remain of 34
- Prometheus: `retention` **and** `retentionSize` set, storage is a PVC not
  `emptyDir`, memory limit set, no CPU limit, selector accepts our
  ServiceMonitors
- Loki: exactly **one** workload (down from 12), no read/write/backend tiers, no
  memcached, no gateway; `auth_enabled: false`, `replication_factor: 1`,
  filesystem storage, compactor retention on, tsdb v13 schema
- Full resource footprint totalled against the node budget — **76% CPU / 48% RAM
  at worst case**
- 13 manifests schema-valid against real Kubernetes and CRD schemas; the
  embedded Grafana dashboard parses as JSON with 5 panels

One thing the first pass got wrong and worth recording: Prometheus and
Alertmanager don't appear as Deployments in rendered output — the Operator
creates them at runtime from custom resources. A naive scan of the render
therefore *omits the two largest consumers* and reports a comfortably wrong
number. The totals above include them.

**Not verified:** nothing has run. No cluster exists yet, so the scrape actually
working, Alloy's log pipeline, and the alert firing are all unrun.
