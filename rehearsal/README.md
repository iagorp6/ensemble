# `rehearsal` — making the node reliable

> *An ensemble rehearses until it can play the same way every time.*

Layer 2 of [ensemble](../README.md). Layer 1 produced a bare Ubuntu VM with an
SSH key on it. This turns that into a hardened, cluster-ready node — and, more
importantly, into a node that can be brought back to exactly this state at any
time, from any state, by running one command.

---

## The property this layer is actually about

**It's idempotent.** Running it twice is indistinguishable from running it
once, and the second run reports zero changes.

That's not a nice-to-have, it's the entire reason configuration management
exists as a category. A shell script answers *"what do I do to a fresh
machine?"* A playbook answers *"what should be true of this machine?"* — and
that's a question you can ask repeatedly, at any time, against a host in any
state.

What it buys, concretely:

- **A partial failure is safe to re-run.** No "which step did it get to?"
- **Drift is correctable.** Someone edited `sshd_config` by hand at 2am. Run it
  again and it's back.
- **`--check` becomes an audit.** It reports what *would* change without
  touching anything, which finds drift before it bites.
- **Rebuilding from scratch stops being frightening**, which is what makes
  `terraform destroy` a normal thing to do rather than a last resort.

Verify it rather than believing me:

```bash
ansible-playbook playbook.yml    # first run: lots of changed
ansible-playbook playbook.yml    # second run: changed=0
```

### Idempotency isn't free

Ansible's modules are declarative and mostly get it for free. But every
`command` and `shell` task is an escape hatch back into imperative scripting,
and each one has to *earn* its idempotency with an explicit guard. There are 22
of them in this layer and every one carries a comment explaining how:

```bash
grep -rn "IDEMPOTENCY:" roles/
```

The three patterns used here:

| Pattern | Where | How it works |
|---|---|---|
| `changed_when: false` | Any pure read (`sshd -T`, `lsblk`, `iptables -C`) | Tells Ansible the task never modifies anything, so it can't pollute the changed count |
| Check-then-act | `doorman` removing Oracle's iptables rules | `iptables -C` tests for the rule; the delete is guarded on that result. A bare `iptables -D` errors on the second run |
| Parse the tool's own output | `warmup` growing the filesystem | `growpart` prints `NOCHANGE` and exits non-zero when already maximal; treating that specific failure as success is what makes it repeatable |

The subtlest case is in `orchestra`. Pulling the kubeconfig back to the workstation
looks like a job for Ansible's `fetch` module — but `fetch` compares the remote
file to the local one, and rewriting the server address afterwards makes them
differ *permanently*, so it re-downloads and re-rewrites on every run. Two
changed tasks, forever. Reading the file and writing the transformed result with
`copy: content:` compares the **final** content instead, so a second run is
genuinely a no-op. Idempotency is a property you have to design for, not one
you get by using the right tool.

---

## The seven roles

Themed names, one standard concept each — same convention as layer 1.

| Role | What it is | What it does |
|---|---|---|
| `warmup` | Base system prep | Timezone, packages, root filesystem growth, swap off |
| `crew` | Operator account | Non-root user with the same SSH key, sudo via a validated drop-in |
| `doorman` | Host firewall | Removes Oracle's preinstalled iptables rules, installs a K3s-compatible ufw policy |
| `lockup` | Hardening | sshd drop-in, unattended security upgrades, fail2ban |
| `roadcase` | Docker | Container runtime for debugging (**not** for the cluster — see below) |
| `orchestra` | K3s | The Kubernetes cluster everything above was preparing for |
| `soundcheck` | Verification | Asserts all of the above is actually true. Changes nothing |

### Order isn't arbitrary

- `warmup` first — everything needs a current apt cache, and the disk has to
  actually be 100 GB before things start filling it.
- `crew` before `lockup` — create the account *before* sshd starts refusing
  logins. Hardening SSH while the only account that can use the hardened config
  doesn't exist yet is how people lock themselves out of cloud VMs.
- `doorman` before `lockup` — so ufw exists for fail2ban to ban into.
- `soundcheck` last, and it only reads.

---

## The trap this layer exists to defuse

**There are two firewalls, and both have to allow a port.**

Layer 1's OCI security list is enforced in Oracle's virtual network, before
packets reach the machine. Oracle's Ubuntu image *also* ships with iptables
rules already loaded — accept established connections, loopback and TCP 22,
then a blanket `REJECT --reject-with icmp-host-prohibited` at the end of each
chain. The `iptables-persistent` package restores them on every boot.

So you open 6443 in the security list, the OCI console shows the port open, and
`kubectl` times out. Nothing in the console is wrong and nothing in any log says
why. This is the most common way an OCI Kubernetes build stalls on day one.

`doorman` removes those rules and puts ufw in charge instead. Not because ufw
is better, but because the blanket REJECT sits at the *end* of the chain, so
anything new has to be inserted before it by numeric index — and indices shift
every time anything else changes. That's a ruleset nobody can reason about six
months later.

### ufw and Kubernetes need care together

Two settings that are easy to miss and produce identical, baffling symptoms:

**Routed traffic must be allowed.** Every pod-to-pod and pod-to-service packet
is *forwarded*, and ufw drops forwarded traffic by default. Get this wrong and
the cluster comes up healthy — every node Ready, every pod Running — while
applications time out talking to each other. Including CoreDNS, which makes the
whole thing look like a DNS problem. It isn't.

**The pod and service CIDRs must be allowed as sources.** Traffic from a pod
arrives at the host from `10.42.x.x`, which is not a network ufw has any reason
to trust.

`soundcheck` asserts both, and asserts the Oracle rules are gone, because "ufw
is configured correctly" and "traffic gets through" are different claims — the
two coexist happily while the blanket REJECT quietly drops everything.

---

## Other things worth knowing

### sshd takes the *first* value; apt takes the *last*

Both are drop-in directories, and they resolve conflicts in opposite
directions. This layer writes to both, a few tasks apart.

`/etc/ssh/sshd_config` starts with `Include /etc/ssh/sshd_config.d/*.conf`, and
sshd uses the **first** value it sees for any keyword. Ubuntu's cloud images
ship `50-cloud-init.conf`, which on many images contains
`PasswordAuthentication yes`. Name your hardening file `99-hardening.conf` and
cloud-init's setting is read first and wins — password auth stays on, while the
file that was supposed to disable it sits there looking correct.

So it's `10-ensemble-hardening.conf`. And `lockup` doesn't trust that either —
it runs `sshd -T`, which prints the *effective* config with every drop-in
merged in the order sshd actually applies them, and asserts against that.

APT is the other way round: `/etc/apt/apt.conf.d/*` is read in lexical order and
the **last** assignment wins, so the unattended-upgrades override is
`52-ensemble-unattended-upgrades` — after Ubuntu's `50unattended-upgrades`.

### Validate configs that can lock you out

Two files here would be unrecoverable to get wrong on a cloud VM with no serial
console: `sudoers` and `sshd_config`. sudo refuses to run *at all* with a
syntax error; sshd refuses to start.

Both tasks use Ansible's `validate:` parameter, which runs a checker against the
candidate file **before** moving it into place — `visudo -cf` and `sshd -t`. If
the check fails, the task fails and the existing file is untouched.

Restarting sshd, incidentally, does not drop your existing connection — the
running session is already forked off the listener. The danger was never the
restart, it was the config.

### fail2ban on modern Ubuntu needs `backend = systemd`

fail2ban defaults to tailing `/var/log/auth.log`. Ubuntu server no longer
installs rsyslog, so that file doesn't exist and never will — authentication
events go to the journal.

Leave the default and fail2ban installs cleanly, starts cleanly, reports itself
active, and bans absolutely nothing, forever. There's no error to find, because
from fail2ban's point of view a log file that never grows is just a quiet
server. It also needs `python3-systemd` present to read the journal at all.

### Docker is here, and K3s doesn't use it

K3s embeds its own containerd. The dockershim that once let Kubernetes drive
Docker was removed in Kubernetes 1.24. Nothing `roadcase` installs ever runs a
pod, and an image you `docker pull` is not visible to the cluster.

It's here as an operator tool — pulling an image by hand to test a registry
credential, running a throwaway container to see what the node's network can
reach, checking that an image `score` built really is arm64 before spending an
hour wondering why a pod crash-loops with `exec format error`. That's ~150 MB
for a debugging convenience, so it's behind `roadcase_install_docker` and can be
dropped if `metronome` makes memory tight. Nothing depends on it.

### The K3s version is pinned

`curl -sfL https://get.k3s.io | sh -` installs whatever is newest at the moment
you run it, which means two nodes built a month apart run different Kubernetes
and the repo can't tell you which. `k3s_version` in
[group_vars/ensemble.yml](group_vars/ensemble.yml) pins it, and changing that
value makes `orchestra` perform an in-place upgrade on the next run.

### `--tls-san` is the flag people miss

Without the public IP as a Subject Alternative Name, the certificate K3s
generates is valid for `127.0.0.1` and the private IP only. `kubectl` from a
workstation connects, receives a certificate that doesn't match the address it
dialled, and fails verification. It looks like a kubeconfig problem and isn't.

The value comes from `node_public_ip` in the inventory — which layer 1
generated. It's the clearest example in the repo of Terraform's outputs being
load-bearing rather than decorative.

---

## Running it

### Prerequisites

Ansible has no supported Windows control node, so this runs from WSL. Ubuntu
26.04 ships without `pip`, so use the distro package:

```bash
sudo apt update && sudo apt install -y ansible
```

Then the collections this layer needs:

```bash
cd rehearsal && ansible-galaxy collection install -r requirements.yml
```

`ansible-core` alone doesn't include `community.general` or `ansible.posix`,
and the failure without them is `couldn't resolve module/action`, which reads
like a typo rather than a missing dependency.

### The inventory comes from layer 1

```bash
cd ../tuning
terraform output -raw ansible_inventory > ../rehearsal/inventory.ini
```

Don't write it by hand. The committed
[inventory.example.ini](inventory.example.ini) exists to show the shape of the
handoff, not to be filled in.

### Run

```bash
cd rehearsal
ansible-playbook playbook.yml
```

Expect 5–10 minutes on the first run, most of it apt and the K3s image pulls.

Then prove the claim:

```bash
ansible-playbook playbook.yml
```

`changed=0`.

### Useful variations

```bash
ansible-playbook playbook.yml --check              # audit: what would change?
ansible-playbook playbook.yml --diff               # show file-level diffs
ansible-playbook playbook.yml --tags soundcheck    # health check, changes nothing
ansible-playbook playbook.yml --tags firewall      # just doorman
ansible-playbook playbook.yml --list-tasks         # what would run, in order
```

`--tags soundcheck` is worth knowing: it re-reads everything itself rather than
trusting variables the other roles registered, so it works standalone against a
node configured weeks ago. That turns it from a build-time check into a drift
detector.

---

## What this hands to `conductor`

A running K3s cluster, and a kubeconfig on your workstation with the server address
already rewritten to the node's public IP:

```bash
export KUBECONFIG=$PWD/kubeconfig.podium
kubectl get nodes
kubectl get pods -A
```

**That file is a credential.** It embeds a client certificate with
cluster-admin rights — anyone holding it owns everything running there. It's
gitignored, and it's the last time in this project that a credential capable of
changing the cluster sits outside it. From layer 4 onward, ArgoCD pulls from Git
and nothing external holds the keys.

---

## When it fails

### `Failed to connect to the host via ssh` on the first run

The host key isn't in `~/.ssh/known_hosts`. Layer 1's runbook ends by SSHing to
the node, which handles it. If you skipped that:

```bash
ssh-keyscan -H <node-ip> >> ~/.ssh/known_hosts
```

If you rebuilt the node, its host key changed and SSH will refuse until the
stale entry is removed: `ssh-keygen -R <node-ip>`.

### `couldn't resolve module/action 'community.general.ufw'`

The collections aren't installed. `ansible-galaxy collection install -r
requirements.yml`.

### Could not get lock /var/lib/dpkg/lock-frontend

cloud-init is still running its first-boot work and holding the dpkg lock. The
playbook's first task waits for exactly this, so if you're seeing it, something
ran out of order — check that `cloud-init status --wait` completed.

### The playbook hangs after `doorman`

The most alarming possible outcome, and the reason rules are added *before*
`ufw enable` rather than after. If it ever happens, the OCI security list is
still in front and unaffected, so the node is recoverable by reverting the
in-guest firewall from a console session or by rebuilding with
`terraform apply -replace`.

### `soundcheck` fails on kube-system pods

On this platform, rule out architecture first. An amd64 image on an aarch64
node crash-loops with `exec format error`. That's the constraint layer 1's
shape choice propagated, and it's the single most likely cause here.

---

## Verified

`soundcheck` runs these on every push, and they pass:

- `ansible-lint` at the **`production` profile**, the strictest one, with the
  collections from `requirements.yml` installed first so module names resolve
  against the real collection instead of being skipped as unknown
- `ansible-playbook --syntax-check` against `inventory.example.ini`, which
  proves all seven roles parse and are reachable from `playbook.yml`

**Not verified:** there is no host to run against. The playbook has never
executed, so the claim this README cares about most, that a second run reports
`changed=0`, is unproven. So are the hardening outcomes, the K3s install, and
the kubeconfig this layer is supposed to hand back to the operator.
