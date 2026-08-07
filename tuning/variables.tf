# =============================================================================
# tuning / variables.tf — the inputs, and the guardrails on them
# =============================================================================
#
# Two jobs in this file.
#
# The obvious one: declare what has to be supplied from outside (account IDs,
# region, sizing) so nothing account-specific is hardcoded in main.tf.
#
# The one that actually matters here: every `validation` block below is a
# guardrail that fails at PLAN time — before a single API call — rather than
# letting a typo become a running, billable resource. The Always Free tier is
# generous but it is not forgiving: it has no hard cap, it just starts
# charging. Encoding those limits as code is the difference between "I read the
# docs once" and "this repo cannot accidentally cost me money."
# =============================================================================


# -----------------------------------------------------------------------------
# Identity — who is calling, and where the resources land
# -----------------------------------------------------------------------------

variable "tenancy_ocid" {
  description = <<-EOT
    OCID of your tenancy — the root of your entire Oracle Cloud account.

    An OCID is Oracle's globally unique resource ID. They look like:
      ocid1.tenancy.oc1..aaaaaaaa<long random string>
    and read left to right as: version, resource type, realm, region, unique id.

    Find it in the OCI Console under Profile -> Tenancy, or copy it out of
    ~/.oci/config where it's already written.

    Needed here even though the provider reads the config file, because listing
    availability domains is a query against the tenancy (root compartment)
    specifically.
  EOT
  type        = string

  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "tenancy_ocid must start with 'ocid1.tenancy.' — you've probably pasted a user or compartment OCID by mistake."
  }
}

variable "compartment_ocid" {
  description = <<-EOT
    OCID of the compartment these resources go in.

    Compartments are OCI's way of grouping resources for access control and
    cost tracking — closer to an AWS account boundary than to a tag. Everything
    in a compartment can be governed by one IAM policy.

    Leave this null and everything lands in the root compartment (the tenancy
    itself), which is the normal shape for a personal free-tier account. In a
    real org you would never build into root; you'd get a dedicated compartment
    so policies and cost reports have somewhere to attach.
  EOT
  type        = string
  default     = null

  validation {
    # The coalesce substitutes a known-good placeholder when the variable is
    # null, so the "unset means root compartment" case passes without the
    # regex ever being handed a null.
    condition     = can(regex("^ocid1\\.(compartment|tenancy)\\.", coalesce(var.compartment_ocid, "ocid1.compartment.unset")))
    error_message = "compartment_ocid must be null (meaning: use the tenancy root) or an OCID starting with 'ocid1.compartment.'."
  }
}

variable "region" {
  description = <<-EOT
    OCI region identifier, e.g. "sa-saopaulo-1", "us-ashburn-1", "eu-frankfurt-1".

    Two things worth knowing before picking one:

      1. Your Always Free resources live in your tenancy's HOME region and
         cannot be moved. Whatever you chose at signup is where this has to go.
      2. Ampere A1 capacity in the free tier is regional and genuinely scarce
         in popular regions. This is the single most common reason a first
         `apply` fails. See tuning/README.md.

    Null means "use the region from the ~/.oci/config profile", which is
    usually the right answer.
  EOT
  type        = string
  default     = null
}

variable "oci_auth" {
  description = <<-EOT
    How the provider authenticates. "ApiKey" reads ~/.oci/config and signs
    requests with your RSA key — the normal choice for a laptop.

    "SecurityToken" uses a short-lived browser session from
    `oci session authenticate`; "InstancePrincipal" lets an OCI VM authenticate
    as itself with no key on disk, which is what you'd reach for if CI ever ran
    this from inside OCI.
  EOT
  type        = string
  default     = "ApiKey"

  validation {
    condition     = contains(["ApiKey", "SecurityToken", "InstancePrincipal", "ResourcePrincipal"], var.oci_auth)
    error_message = "oci_auth must be one of: ApiKey, SecurityToken, InstancePrincipal, ResourcePrincipal."
  }
}

variable "oci_config_profile" {
  description = "Which profile to read from ~/.oci/config. 'DEFAULT' unless you have several tenancies."
  type        = string
  default     = "DEFAULT"
}


# -----------------------------------------------------------------------------
# Naming
# -----------------------------------------------------------------------------

variable "project_name" {
  description = <<-EOT
    Prefix for every display name and tag. Keeping one knob for this means the
    OCI console reads as a coherent set of things rather than a pile of
    defaults, and `terraform destroy` leaving something behind becomes obvious.
  EOT
  type        = string
  default     = "ensemble"

  validation {
    # Used to build DNS labels further down, which OCI restricts hard.
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name must be lowercase, start with a letter, and be 2-21 characters of letters, digits or hyphens."
  }
}


# -----------------------------------------------------------------------------
# Compute sizing — where the Always Free guardrails live
# -----------------------------------------------------------------------------

variable "instance_shape" {
  description = <<-EOT
    The OCI compute shape — the hardware profile.

    VM.Standard.A1.Flex is the Ampere ARM shape and the only realistic choice
    for this project. "Flex" means you choose the OCPU and RAM numbers rather
    than picking from fixed t-shirt sizes.

    VM.Standard.E2.1.Micro (AMD, 1/8 OCPU, 1 GB RAM) is also Always Free and is
    allowed here for completeness, but it will not run K3s plus ArgoCD plus a
    Prometheus stack. Don't reach for it.

    IMPORTANT DOWNSTREAM CONSEQUENCE: A1 is aarch64, not x86_64. Everything
    that lands on this node has to be ARM-native. That is why `score` (layer 3)
    builds linux/arm64 images and why the Helm charts in `metronome` (layer 6)
    need multi-arch support. Choosing this shape is a decision about the whole
    platform, not just this file.
  EOT
  type        = string
  default     = "VM.Standard.A1.Flex"

  validation {
    condition     = contains(["VM.Standard.A1.Flex", "VM.Standard.E2.1.Micro"], var.instance_shape)
    error_message = "instance_shape must be VM.Standard.A1.Flex or VM.Standard.E2.1.Micro — the only Always Free eligible shapes."
  }
}

variable "instance_ocpus" {
  description = <<-EOT
    OCPUs for the flexible shape. On Ampere, 1 OCPU = 1 physical core = 1 vCPU
    (no hyperthreading), so this number is honest in a way x86 OCPU counts
    aren't.

    Default 2, and that is not an arbitrary number — see the free-tier maths in
    the `enforce_always_free` variable below.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4 && floor(var.instance_ocpus) == var.instance_ocpus
    error_message = "instance_ocpus must be a whole number from 1 to 4 (4 is the per-tenancy A1 ceiling)."
  }
}

variable "instance_memory_gbs" {
  description = <<-EOT
    RAM in GB. Default 12, which is the free 24/7 allowance and comfortably
    enough for K3s + ArgoCD + Prometheus + Loki + Grafana + a small app, once
    layer 6 is sized with retention limits rather than defaults.
  EOT
  type        = number
  default     = 12

  validation {
    condition     = var.instance_memory_gbs >= 1 && var.instance_memory_gbs <= 24
    error_message = "instance_memory_gbs must be between 1 and 24 (24 is the per-tenancy A1 ceiling)."
  }

  # Cross-variable validation (Terraform >= 1.9). OCI rejects A1 shapes outside
  # a 1-64 GB-per-OCPU ratio, and it rejects them at apply time with an opaque
  # 400. Catching it at plan time turns a confusing API error into a sentence
  # that says what to change.
  validation {
    condition = (
      var.instance_shape != "VM.Standard.A1.Flex" ||
      (var.instance_memory_gbs >= var.instance_ocpus * 1 && var.instance_memory_gbs <= var.instance_ocpus * 64)
    )
    error_message = "VM.Standard.A1.Flex requires between 1 and 64 GB of memory per OCPU. Adjust instance_memory_gbs or instance_ocpus so the ratio fits."
  }
}

variable "boot_volume_size_gbs" {
  description = <<-EOT
    Boot volume size. 50 GB is OCI's minimum for a VM.

    The Always Free storage grant is 200 GB TOTAL across every boot volume and
    block volume in the tenancy — boot volumes are not exempt. 100 GB here is
    deliberately half the grant: plenty for the OS, container images,
    Prometheus TSDB and Loki chunks, while leaving room to build a second node
    later without going over.

    Note for later: OCI only grows the *volume*. Ubuntu's cloud image extends
    the root filesystem to match on first boot, but it is worth verifying with
    `df -h` — `rehearsal` (layer 2) asserts it rather than assuming.
  EOT
  type        = number
  default     = 100

  validation {
    condition     = var.boot_volume_size_gbs >= 50 && var.boot_volume_size_gbs <= 200
    error_message = "boot_volume_size_gbs must be between 50 (OCI minimum) and 200 (the entire Always Free storage grant)."
  }
}

variable "enforce_always_free" {
  description = <<-EOT
    Master guardrail. Leave it true unless you have deliberately decided to pay.

    THE MATHS, because "Always Free" is more subtle than it sounds:

    Oracle does not grant you "4 OCPUs and 24 GB". It grants a monthly budget of
    1,500 OCPU-hours and 9,000 GB-hours on A1. An average month is ~730 hours,
    so what you can run CONTINUOUSLY for free is:

        1,500 OCPU-hours / 730 h  =  2.05 OCPUs
        9,000 GB-hours   / 730 h  = 12.33 GB

    That is where the 2 OCPU / 12 GB defaults come from.

    You *can* create a 4 OCPU / 24 GB instance — the console will let you, and
    plenty of blog posts tell you to. Run it 24/7 and you burn 2,920 OCPU-hours
    and 17,520 GB-hours a month, roughly double the grant, and Oracle bills the
    overage. It is free only if you run it for about half the month.

    When true, the precondition in main.tf refuses to build anything that would
    exceed the continuous-use allowance. Flipping it to false is an explicit,
    reviewable act rather than a slip.
  EOT
  type        = bool
  default     = true
}


# -----------------------------------------------------------------------------
# Placement
# -----------------------------------------------------------------------------

variable "availability_domain_index" {
  description = <<-EOT
    Which availability domain to place the instance in, zero-indexed.

    An AD is an isolated datacentre within a region. Most regions outside the
    big US/EU ones have exactly one, in which case this must stay 0.

    This is a variable rather than a hardcoded 0 for one practical reason: free
    tier A1 capacity is tracked per-AD, so the standard response to
    "Out of host capacity" in a multi-AD region is to try 1, then 2. See
    tuning/README.md.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.availability_domain_index >= 0 && var.availability_domain_index <= 2
    error_message = "availability_domain_index must be 0, 1 or 2 — no OCI region has more than three availability domains."
  }
}

variable "ubuntu_version" {
  description = <<-EOT
    Ubuntu LTS version to look up in OCI's image catalogue.

    24.04 (Noble) is the default because it is what K3s, Docker and the Helm
    charts in later layers are best tested against. This string is matched
    exactly against OCI's `operating_system_version`, which is also what keeps
    the "Minimal" image variants (published as "24.04 Minimal") out of the
    results — those ship without cloud-init modules Ansible expects.
  EOT
  type        = string
  default     = "24.04"
}


# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vcn_cidr" {
  description = <<-EOT
    Address range for the Virtual Cloud Network — the private network this all
    sits inside. 10.0.0.0/16 gives 65k addresses, which is absurd overkill for
    one VM and exactly what you want anyway: the cost of a large private range
    is zero, and the cost of running out is renumbering everything.

    Worth avoiding: 10.42.0.0/16 and 10.43.0.0/16, which K3s uses by default
    for pod and service networks. Overlap there produces routing failures that
    look like random pod-to-pod timeouts.
  EOT
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0))
    error_message = "vcn_cidr must be valid CIDR notation, e.g. 10.0.0.0/16."
  }
}

variable "subnet_cidr" {
  description = "Address range for the public subnet the node's NIC lives in. Must sit inside vcn_cidr."
  type        = string
  default     = "10.0.1.0/24"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be valid CIDR notation, e.g. 10.0.1.0/24."
  }
}

variable "ssh_allowed_cidr" {
  description = <<-EOT
    Who may reach port 22.

    The default is 0.0.0.0/0 — the whole internet — and that is a deliberate,
    uncomfortable default rather than a good one. Home connections get dynamic
    addresses, so pinning this to a single IP is the fastest way to lock
    yourself out of a machine you cannot console into easily.

    The honest defence-in-depth position for this repo: this rule is wide, and
    `rehearsal` (layer 2) is what makes port 22 safe to expose — password auth
    off, root login off, keys only, fail2ban watching. Two layers, each doing
    the part it is actually good at.

    If you have a static address, set it to "<your.ip>/32" and get both.
    Check with: curl -s https://ifconfig.me
  EOT
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "ssh_allowed_cidr must be valid CIDR notation, e.g. 203.0.113.4/32 or 0.0.0.0/0."
  }
}

variable "kube_api_allowed_cidr" {
  description = <<-EOT
    Who may reach the Kubernetes API on port 6443.

    This one defaults to 0.0.0.0/0 too so that `kubectl` works from a laptop on
    a changing IP, but it deserves more suspicion than SSH does: the K3s API
    is the front door to the whole cluster, and unlike sshd it has no fail2ban
    in front of it. It is protected by certificate/token auth only.

    Narrow this the moment you can. The alternative worth knowing is not
    narrowing it at all but closing it entirely and reaching the API through an
    SSH tunnel, which is what a real deployment would do.
  EOT
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.kube_api_allowed_cidr, 0))
    error_message = "kube_api_allowed_cidr must be valid CIDR notation."
  }
}

variable "open_http_ports" {
  description = <<-EOT
    Open 80 and 443 to the internet for the K3s ingress controller (Traefik,
    which K3s ships by default) to serve the app that `score` builds and
    `conductor` deploys.

    Set false if you would rather reach everything by SSH tunnel until there is
    actually something worth serving.
  EOT
  type        = bool
  default     = true
}


# -----------------------------------------------------------------------------
# SSH access
# -----------------------------------------------------------------------------

variable "ssh_public_key_path" {
  description = <<-EOT
    Path to the PUBLIC half of your SSH keypair — the .pub file. The private
    key is never read by Terraform and must never be.

    This key is injected into the image's cloud-init metadata at first boot and
    is the only way into the machine. There is no password, and OCI has no
    "reset root password" button for a VM. Get this wrong and the recovery path
    is detaching the boot volume and mounting it on another instance.

    ~ is expanded, so the default works on Linux, macOS and WSL alike.
  EOT
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_public_key" {
  description = <<-EOT
    The public key material itself ("ssh-ed25519 AAAA... comment"), as an
    alternative to reading it from disk. Takes precedence over
    ssh_public_key_path when set.

    This exists for CI, where the key arrives as an environment variable rather
    than a file. Public keys are not secrets — publishing one is harmless — so
    there is nothing wrong with it appearing in a tfvars file.
  EOT
  type        = string
  default     = null
}
