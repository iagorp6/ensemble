# `conductor/manifests/` — the desired state of the cluster

**Everything in this directory is running on the cluster. Everything running on
the cluster is in this directory.**

That's not a convention, it's enforced. The `downbeat` Application
([../application.yaml](../application.yaml)) watches this path with
`selfHeal: true` and `prune: true`:

- Change a file → the cluster changes to match.
- `kubectl edit` something → ArgoCD reverts it, usually within seconds.
- `git rm` a file → the resource is deleted from the cluster.

## How to deploy something

```bash
# edit or add manifests here
git add conductor/manifests/
git commit -m "Scale overture to 3 replicas"
git push
```

That's the whole procedure. There is no second step, no pipeline to trigger, no
`kubectl apply`. ArgoCD polls this repository (every 3 minutes by default) and
reconciles.

To skip the wait:

```bash
kubectl -n argocd patch application downbeat --type merge \
  -p '{"operation":{"sync":{"revision":"main"}}}'
```

## Layout

```
manifests/
└── overture/          # the demo application — layer 3 replaces its image
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

One directory per workload. `downbeat` recurses, so a new directory is picked
up with no other change.

## Adding something bigger than plain YAML

`downbeat` applies anything valid it finds here — **including other
`Application` objects**. That's the app-of-apps pattern, and it's how
Helm-based components arrive without this directory turning into a pile of
rendered templates.

Layer 6 will land as roughly this:

```yaml
# manifests/metronome/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metronome
  namespace: argocd
spec:
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: <pinned>
    helm:
      valueFiles: [$values/metronome/values.yaml]
  # ...
```

`downbeat` deploys that Application; that Application deploys the chart. One
committed file, arbitrarily deep.

## What does *not* belong here

**Secrets in plaintext.** This directory is public, and a Kubernetes `Secret` is
base64, not encryption.

That gap is closed. [`backstage/`](../../backstage/) holds SOPS-encrypted
secrets that are safe to commit here, and
[`backstage/application.yaml`](backstage/application.yaml) in this directory is
the Application that deploys them — ArgoCD's repo-server decrypts at sync time,
in memory.

To add a secret: `sops edit backstage/secrets.enc.yaml`, commit, push. Same
workflow as everything else in this directory, which is the point.
