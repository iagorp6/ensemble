#!/usr/bin/env python3
"""Assert the decisions the READMEs claim are still true of the rendered charts.

Run by .github/workflows/soundcheck.yml against /tmp/rendered/, after Helm has
templated every chart with this repo's values files.

WHY THIS EXISTS
---------------
`kubeconform` proves the rendered output is valid Kubernetes. It says nothing
about whether it is the output we decided on.

Helm silently ignores values it does not recognise — a key renamed upstream, or
one that never existed, produces no error at all. That already happened once
here: `applicationSet.enabled: false` is not a key in argo-cd chart 10.x, and
writing it would have documented a component as disabled while it ran.

So every claim in the layer READMEs that can be checked against a render is
checked here: the K3s control-plane targets that do not exist, Prometheus's two
retention limits, the absence of CPU limits, Loki cut down to one workload, and
no plaintext token anywhere in the Alertmanager config.

Standard library plus PyYAML, which the runner already has.
"""

from __future__ import annotations

import base64
import pathlib
import re
import sys

import yaml

# Where `helm template` put its output. Overridable so this can be run locally
# against a scratch directory rather than only inside CI.
RENDERED = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/rendered")

failures: list[str] = []
checks = 0


def check(label: str, condition: bool, detail: object = "") -> None:
    global checks
    checks += 1
    if condition:
        print(f"  [OK  ] {label}")
    else:
        print(f"  [FAIL] {label}" + (f"   -> {detail}" if detail != "" else ""))
        failures.append(label)


def load(name: str) -> list[dict]:
    path = RENDERED / name
    if not path.exists():
        failures.append(f"{name} was not rendered")
        return []
    return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]


def mebibytes(value: str | None) -> float:
    if not value:
        return 0.0
    m = re.match(r"^(\d+(?:\.\d+)?)(Mi|Gi|M|G|Ki)?$", str(value))
    if not m:
        return 0.0
    scale = {"Mi": 1, "Gi": 1024, "M": 0.954, "G": 977, "Ki": 1 / 1024, "": 1 / 1048576}
    return scale[m.group(2) or ""] * float(m.group(1))


def millicores(value: str | None) -> float:
    if not value:
        return 0.0
    value = str(value)
    return float(value[:-1]) if value.endswith("m") else float(value) * 1000


# =============================================================================
print("\n=== conductor: ArgoCD ===")
argocd = load("argocd.yaml")
workloads = {d["metadata"]["name"] for d in argocd if d.get("kind") in ("Deployment", "StatefulSet")}

check("dex disabled (no SSO broker to run)", not any("dex" in n for n in workloads), sorted(workloads))
check("notifications disabled", not any("notifications" in n for n in workloads))
# Documented as NOT disableable in chart 10.x. If a future chart adds the key
# back, this flips and the README needs updating — which is the point.
check("applicationSet present (cannot be disabled in chart 10.x)",
      any("applicationset" in n for n in workloads))
check("no Ingress for the ArgoCD UI", not any(d.get("kind") == "Ingress" for d in argocd))

params = [d for d in argocd if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "argocd-cmd-params-cm"]
check("server.insecure set (TLS terminates at the edge)",
      bool(params) and str(params[0].get("data", {}).get("server.insecure", "")).lower() == "true")

cm = [d for d in argocd if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "argocd-cm"]
check("kustomize exec plugins enabled for KSOPS",
      bool(cm) and "--enable-exec" in cm[0].get("data", {}).get("kustomize.buildOptions", ""))

repo = [d for d in argocd if d.get("kind") == "Deployment" and d["metadata"]["name"] == "argocd-repo-server"]
if repo:
    spec = repo[0]["spec"]["template"]["spec"]
    init = [c for c in spec.get("initContainers", []) if c["name"] == "install-ksops"]
    check("ksops init container present", bool(init))
    # The -arm64 suffixed tag looks right on an Ampere node and is single-arch.
    check("ksops uses the multi-arch tag, not the -arm64 one",
          bool(init) and init[0]["image"] == "viaductoss/ksops:v4.5.1",
          init[0]["image"] if init else "")
    mounts = {m["mountPath"] for m in spec["containers"][0].get("volumeMounts", [])}
    check("age key mounted into the repo-server", "/home/argocd/.config/sops/age" in mounts)
else:
    check("repo-server rendered", False)

# =============================================================================
print("\n=== metronome: Prometheus and the K3s trap ===")
kps = load("kps.yaml")

monitors = {d["metadata"]["name"] for d in kps if d.get("kind") == "ServiceMonitor"}
for component in ("kube-controller-manager", "kube-scheduler", "kube-proxy", "kube-etcd"):
    check(f"no ServiceMonitor for {component} (does not exist on K3s)",
          not any(component in m for m in monitors))

groups = {g["name"] for d in kps if d.get("kind") == "PrometheusRule" for g in d["spec"].get("groups", [])}
for group in ("etcd", "kubernetes-system-controller-manager",
              "kubernetes-system-scheduler", "kubernetes-system-kube-proxy"):
    check(f"no alert rule group '{group}'", group not in groups)
check("no API-server SLO burn-rate groups (expensive, nobody to page)",
      not any("burnrate" in g or "slo" in g.lower() for g in groups))

prom = [d for d in kps if d.get("kind") == "Prometheus"]
if prom:
    spec = prom[0]["spec"]
    check("retention set (time bound)", spec.get("retention") == "7d", spec.get("retention"))
    # The one that actually prevents a full disk.
    check("retentionSize set (disk bound)", bool(spec.get("retentionSize")), spec.get("retentionSize"))
    check("storage is a PVC, not emptyDir",
          "volumeClaimTemplate" in (spec.get("storage") or {}))
    check("scrape interval widened from the chart default",
          spec.get("scrapeInterval") == "60s", spec.get("scrapeInterval"))
    limits = (spec.get("resources") or {}).get("limits") or {}
    check("memory limit set (incompressible resource)", "memory" in limits)
    check("no CPU limit (CFS throttles even on an idle node)", "cpu" not in limits, limits)
    check("selects ServiceMonitors regardless of release label",
          not spec.get("serviceMonitorSelector"))
else:
    check("Prometheus custom resource rendered", False)

# Prometheus and Alertmanager are created by the Operator from custom resources,
# so they are NOT Deployments in the render. Totalling only the Deployments
# omits the two largest consumers and reports a comfortably wrong number.
print("\n=== metronome: the footprint actually fits the node ===")
cpu = req = lim = 0.0
for doc in kps + load("loki.yaml") + load("alloy.yaml"):
    kind = doc.get("kind")
    if kind in ("Deployment", "StatefulSet", "DaemonSet"):
        replicas = 1 if kind == "DaemonSet" else (doc["spec"].get("replicas") or 1)
        for c in doc["spec"]["template"]["spec"].get("containers", []):
            r = c.get("resources") or {}
            cpu += millicores((r.get("requests") or {}).get("cpu")) * replicas
            req += mebibytes((r.get("requests") or {}).get("memory")) * replicas
            lim += mebibytes((r.get("limits") or {}).get("memory")) * replicas
    elif kind in ("Prometheus", "Alertmanager"):
        r = doc["spec"].get("resources") or {}
        replicas = doc["spec"].get("replicas") or 1
        cpu += millicores((r.get("requests") or {}).get("cpu")) * replicas
        req += mebibytes((r.get("requests") or {}).get("memory")) * replicas
        lim += mebibytes((r.get("limits") or {}).get("memory")) * replicas

# ArgoCD + overture, measured; K3s and system, approximate.
OTHER_CPU, OTHER_REQ, OTHER_LIM = 600 + 500, 1088 + 1024, 1792 + 1024
NODE_CPU, NODE_MEM = 2000, 12595   # 2 OCPU, 12.3 GB continuous on Always Free

print(f"       metronome: {cpu:.0f}m cpu, {req:.0f}Mi requested, {lim:.0f}Mi at limits")
check(f"total CPU requests fit 2 OCPU ({cpu + OTHER_CPU:.0f}m / {NODE_CPU}m)",
      cpu + OTHER_CPU < NODE_CPU)
check(f"worst-case memory fits the free tier ({lim + OTHER_LIM:.0f}Mi / {NODE_MEM}Mi)",
      lim + OTHER_LIM < NODE_MEM)

# =============================================================================
print("\n=== metronome: Loki cut down from SimpleScalable ===")
loki = load("loki.yaml")
loki_workloads = {d["metadata"]["name"] for d in loki if d.get("kind") in ("Deployment", "StatefulSet", "DaemonSet")}
check("exactly one Loki workload (chart default is twelve pods)",
      len(loki_workloads) == 1, sorted(loki_workloads))
check("no read/write/backend tiers", not any(n.endswith(("-read", "-write", "-backend")) for n in loki_workloads))
check("no memcached caches", not any("cache" in n for n in loki_workloads))
check("no nginx gateway", not any("gateway" in n for n in loki_workloads))

conf_maps = [d for d in loki if d.get("kind") == "ConfigMap" and "config.yaml" in (d.get("data") or {})]
if conf_maps:
    conf = yaml.safe_load(conf_maps[0]["data"]["config.yaml"])
    check("auth disabled (single tenant)", conf.get("auth_enabled") is False)
    check("replication_factor 1", conf.get("common", {}).get("replication_factor") == 1)
    storage = conf.get("common", {}).get("storage", {})
    check("filesystem storage, not s3", "filesystem" in storage and "s3" not in storage, list(storage))
    # retention_period is advisory until the compactor is told to delete.
    check("compactor retention enabled", conf.get("compactor", {}).get("retention_enabled") is True)
    check("ingestion rate capped", bool(conf.get("limits_config", {}).get("ingestion_rate_mb")))
else:
    check("Loki config rendered", False)

# =============================================================================
print("\n=== metronome: the token never appears in the render ===")
secrets = [d for d in kps if d.get("kind") == "Secret" and "alertmanager" in d["metadata"]["name"]]
am_config = None
for s in secrets:
    for key, value in (s.get("data") or {}).items():
        if "alertmanager.yaml" in key:
            am_config = yaml.safe_load(base64.b64decode(value))

if am_config:
    receiver = [r for r in am_config["receivers"] if r["name"] == "maestro"][0]
    webhook = receiver["webhook_configs"][0]
    check("webhook targets the pod-network gateway",
          webhook["url"].startswith("http://10.42.0.1:"), webhook["url"])
    check("bearer credentials read from a mounted file, not inlined",
          webhook.get("http_config", {}).get("authorization", {}).get("credentials_file", "").endswith("/token"))
    # The whole point of backstage: nothing secret in a public repo, including
    # in anything rendered from it.
    check("no plaintext token anywhere in the rendered Alertmanager config",
          "ensemble-demo-token" not in str(am_config))
    check("send_resolved on (otherwise recovery is never reported)",
          webhook.get("send_resolved") is True)
    check("Watchdog routed to the null receiver",
          any(r.get("receiver") == "null" for r in am_config["route"].get("routes", [])))
else:
    check("Alertmanager config rendered", False)

# =============================================================================
print()
if failures:
    print(f"{len(failures)} of {checks} assertions failed:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print(f"all {checks} assertions hold")
