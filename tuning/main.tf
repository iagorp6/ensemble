# =============================================================================
# tuning / main.tf — the venue
# =============================================================================
#
# `tuning` is layer 1 of ensemble. Nothing else in this repo can run until this
# does: rehearsal has no host to configure, conductor has no cluster to sync to,
# metronome has nothing to scrape.
#
# What it builds, in the order the graph resolves it:
#
#   stage        (VCN)              the private network everything lives in
#   stage_door   (Internet Gateway) the route in and out
#   stage_routes (Route Table)      "send anything non-local to the door"
#   door_policy  (Security List)    who is allowed through, on which port
#   pit          (Subnet)           the slice of the network the NIC attaches to
#   podium       (Compute Instance) the machine itself
#
# The names are the orchestra metaphor, one per OCI concept. Every resource
# carries a comment naming the standard term so the mapping is never a guess.
#
# One thing to notice while reading: nothing here says "build the VCN first."
# Terraform derives that from the references — `oci_core_subnet.pit` mentions
# `oci_core_vcn.stage.id`, so the VCN must exist first. The dependency graph is
# a side effect of writing down what refers to what. This is the whole trick of
# declarative infrastructure, and it is why an `apply` that half-fails can be
# re-run safely: Terraform recomputes the graph against reality each time.
# =============================================================================


locals {
  # Everything lands in the tenancy root unless a compartment was named. For a
  # personal free-tier account the root IS the compartment, so this keeps the
  # common case down to one required variable.
  compartment_id = coalesce(var.compartment_ocid, var.tenancy_ocid)

  # Prefer inline key material (CI) over a file on disk (laptop). `pathexpand`
  # turns "~/.ssh/id_ed25519.pub" into a real path; `trimspace` strips the
  # trailing newline, which OCI's metadata service otherwise treats as part of
  # the key and silently rejects — producing a VM that builds fine and refuses
  # every SSH connection. That failure is genuinely hard to diagnose from the
  # outside, hence the trim.
  ssh_public_key = trimspace(
    var.ssh_public_key != null ? var.ssh_public_key : file(pathexpand(var.ssh_public_key_path))
  )

  # The node's short hostname. Declared once here because both the VNIC's
  # DNS registration and the internal FQDN output have to agree on it.
  node_hostname = "podium"

  # Freeform tags on every resource. Tags are how you answer "what is this and
  # can I delete it?" six months later, and how you attribute cost once there
  # is more than one project in the tenancy.
  common_tags = {
    "project"   = var.project_name
    "layer"     = "tuning"
    "managedBy" = "terraform"
  }
}


# =============================================================================
# DATA SOURCES — reading what already exists
# =============================================================================
#
# A `resource` block creates and owns something. A `data` block only reads.
# Terraform will never modify or delete anything a data source touches, and
# data sources are re-read on every plan, so they always reflect current
# reality rather than whatever was true when state was last written.
# =============================================================================

# The availability domains in this region. Listing them is a tenancy-level
# query, which is why var.tenancy_ocid is required even when everything else
# is going into a sub-compartment.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# The latest Ubuntu image OCI publishes for this shape.
#
# Pinning to "latest" rather than a fixed image OCID is a real trade-off, and
# it goes the way it does because of what sits downstream. A fixed OCID gives
# perfectly reproducible builds but goes stale, and a months-old image means
# every rebuild starts with a backlog of unapplied security patches. Here the
# node is disposable and `rehearsal` brings it to a known state immediately
# after, so "newest patched base" beats "byte-identical base".
#
# The shape filter is doing quiet but critical work: asking for images
# compatible with an A1 shape is what returns aarch64 builds. Ask for the same
# Ubuntu version against an AMD shape and you get x86_64 images instead.
data "oci_core_images" "ubuntu" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = var.instance_shape
  state                    = "AVAILABLE"

  sort_by    = "TIMECREATED"
  sort_order = "DESC"
}


# =============================================================================
# NETWORK
# =============================================================================

# --- stage: the Virtual Cloud Network ------------------------------------------
#
# The VCN is a software-defined private network inside an OCI region: an
# address range, and the routing and firewall rules that govern it. Nothing in
# it is reachable from the internet until something below explicitly says so.
resource "oci_core_vcn" "stage" {
  compartment_id = local.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.project_name}-vcn"

  # Enables OCI's internal DNS for this network, so hosts can resolve each
  # other by name (podium.pit.ensemble.oraclevcn.com) instead of by IP. Not
  # strictly needed with one node, but it costs nothing and the day a second
  # node appears, name resolution already works.
  #
  # OCI restricts this hard: alphanumeric only, max 15 chars, must start with a
  # letter. No hyphens — which is why it's not just var.project_name with the
  # separator left in.
  dns_label = substr(replace(var.project_name, "-", ""), 0, 15)

  freeform_tags = local.common_tags
}

# --- stage_door: the Internet Gateway ------------------------------------------
#
# An IGW is the VCN's connection to the public internet. It is bidirectional
# and it is not a NAT: instances behind it need their own public IPs to be
# reachable, which is what create_vnic_details.assign_public_ip provides below.
#
# The gateway existing is necessary but not sufficient — traffic only uses it
# if a route table points at it. That separation is deliberate on OCI's part:
# it lets you have a gateway attached while routing only specific ranges
# through it.
resource "oci_core_internet_gateway" "stage_door" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.stage.id
  display_name   = "${var.project_name}-igw"
  enabled        = true

  freeform_tags = local.common_tags
}

# --- stage_routes: the Route Table ---------------------------------------------
#
# Only one rule is needed. Traffic destined for the VCN's own range is routed
# locally by OCI without any rule at all; everything else ("0.0.0.0/0") goes to
# the internet gateway.
#
# This is a dedicated route table rather than an edit to the VCN's default one.
# The reason is destroy-time behaviour: Terraform can cleanly delete a resource
# it created, but a "default" object it merely modified has no delete — it just
# gets orphaned in whatever state the last apply left it. Owning the object
# outright keeps `terraform destroy` genuinely complete.
resource "oci_core_route_table" "stage_routes" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.stage.id
  display_name   = "${var.project_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.stage_door.id
    description       = "Default route to the internet via the VCN's internet gateway"
  }

  freeform_tags = local.common_tags
}

# --- door_policy: the Security List --------------------------------------------
#
# OCI has two firewall mechanisms and it is worth being clear on the difference,
# because mixing them up produces rules that appear correct and do nothing:
#
#   Security lists         attach to a SUBNET. Every VNIC in that subnet gets
#                          the rules, whether it wants them or not.
#   Network security groups attach to a VNIC. Membership is explicit, and NSGs
#                          can reference each other ("allow from anything in the
#                          database NSG"), which is how you express real tiering.
#
# NSGs are the better tool at scale. A security list is the right tool here:
# one subnet, one instance, one uniform policy, and the rules stay visible in
# one place instead of being a property of the compute resource.
#
# These rules are STATEFUL, which is the default. A stateful rule tracks
# connections, so allowing inbound 443 automatically permits the response
# traffic back out. Stateless rules require you to write both directions and
# exist mainly for very high-throughput cases where connection tracking is the
# bottleneck. Not a problem two ARM cores will ever have.
#
# THE LAYER BELOW THIS ONE: these rules are enforced in OCI's virtual network,
# before packets reach the machine. Ubuntu's OCI image ALSO ships with iptables
# rules that reject nearly everything except port 22. Both have to allow a port
# for it to work, and forgetting the second one is the classic OCI trap — the
# console shows the port open, the connection still times out. `rehearsal`
# (layer 2) is where the in-guest side gets handled.
resource "oci_core_security_list" "door_policy" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.stage.id
  display_name   = "${var.project_name}-sl"

  # --- Egress ---------------------------------------------------------------
  # Wide open outbound. The node has to pull Ubuntu packages, container images
  # from GHCR, Helm charts and K3s releases. Locking egress down to specific
  # destinations is a real hardening step, but the destination list for a
  # Kubernetes node is long and changes without warning, so the honest position
  # is: this is open on purpose, and the value would be in egress *logging*
  # rather than egress blocking.
  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Allow all outbound - package repos, container registries, Helm charts"
  }

  # --- Ingress: SSH ---------------------------------------------------------
  # Protocol numbers are IANA's, as strings: "6" TCP, "17" UDP, "1" ICMP.
  ingress_security_rules {
    protocol    = "6"
    source      = var.ssh_allowed_cidr
    source_type = "CIDR_BLOCK"
    description = "SSH - the only way in, and how rehearsal (layer 2) reaches this node"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # --- Ingress: Kubernetes API ----------------------------------------------
  # K3s serves its API on 6443. This is what makes `kubectl` work from a
  # laptop, and what ArgoCD's CLI talks to during layer 4 bootstrap.
  ingress_security_rules {
    protocol    = "6"
    source      = var.kube_api_allowed_cidr
    source_type = "CIDR_BLOCK"
    description = "Kubernetes API server (K3s) - kubectl and ArgoCD CLI access"

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # --- Ingress: HTTP / HTTPS ------------------------------------------------
  # For the Traefik ingress controller K3s installs by default, which is what
  # will eventually serve the app from `score` and the Grafana UI from
  # `metronome`.
  #
  # `dynamic` generates zero or one block depending on a variable. Terraform
  # has no `if` for blocks, so iterating over a list that is either empty or
  # single-element is the idiom for "include this conditionally".
  dynamic "ingress_security_rules" {
    for_each = var.open_http_ports ? [80, 443] : []

    content {
      protocol    = "6"
      source      = "0.0.0.0/0"
      source_type = "CIDR_BLOCK"
      description = "HTTP/HTTPS to the K3s ingress controller (port ${ingress_security_rules.value})"

      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # --- Ingress: ICMP, and why this rule is not optional ---------------------
  #
  # Type 3 Code 4 is "Destination Unreachable - Fragmentation Needed". It is
  # the mechanism Path MTU Discovery uses: a router that cannot forward an
  # oversized packet sends this back so the sender knows to use smaller ones.
  #
  # Block it and you get one of the nastiest classes of network bug there is.
  # Small packets work perfectly — SSH connects, pings succeed, short HTTP
  # requests return — while anything large silently hangs forever. `apt update`
  # stalls at 0%, `docker pull` freezes mid-layer, and nothing in any log says
  # why. OCI's own default security list includes this rule; anyone writing
  # their own from scratch tends to leave it out and then loses an evening.
  ingress_security_rules {
    protocol    = "1"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "ICMP fragmentation-needed - required for Path MTU Discovery, do not remove"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # All ICMP from inside the VCN, so hosts here can diagnose each other.
  ingress_security_rules {
    protocol    = "1"
    source      = var.vcn_cidr
    source_type = "CIDR_BLOCK"
    description = "All ICMP within the VCN - ping and traceroute between internal hosts"

    icmp_options {
      type = 3
    }
  }

  freeform_tags = local.common_tags
}

# --- pit: the public subnet ----------------------------------------------------
#
# "Public" is not a checkbox on a subnet — it is an emergent property of three
# things being true together: the subnet permits public IPs, its route table
# points at an internet gateway, and the instance actually requests one. All
# three are wired up here and in the instance below.
#
# A regional subnet (the default: no availability_domain set) spans every AD in
# the region rather than being pinned to one. That matters for the capacity
# problem — if A1 capacity forces the instance into a different AD, the subnet
# does not have to be rebuilt to follow it.
resource "oci_core_subnet" "pit" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.stage.id
  cidr_block     = var.subnet_cidr
  display_name   = "${var.project_name}-public-subnet"
  dns_label      = "pit"

  route_table_id    = oci_core_route_table.stage_routes.id
  security_list_ids = [oci_core_security_list.door_policy.id]

  # The double negative is OCI's, not mine: false means public IPs ARE allowed.
  prohibit_public_ip_on_vnic = false

  freeform_tags = local.common_tags
}


# =============================================================================
# COMPUTE
# =============================================================================

# --- podium: where the ensemble stands -----------------------------------------
#
# One Ampere A1 instance. By the end of this project it runs K3s, ArgoCD, a
# Prometheus/Grafana/Loki stack and the app that `score` builds — which is a
# lot for two cores, and is exactly why `maestro` (layer 7) runs on the laptop
# instead of here.
resource "oci_core_instance" "podium" {
  compartment_id = local.compartment_id
  display_name   = "${var.project_name}-node"

  # Index into the AD list from the data source. Bump
  # availability_domain_index if OCI reports it is out of A1 capacity here.
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name

  shape = var.instance_shape

  # Flexible shapes need explicit sizing; fixed shapes (E2.1.Micro) ignore it.
  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  source_details {
    source_type = "image"

    # [0] is the newest image, because the data source sorted by creation time
    # descending.
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.pit.id
    display_name     = "${var.project_name}-vnic"
    assign_public_ip = true

    # Registers this name in the VCN's internal DNS, giving the node the stable
    # internal address podium.pit.<dns_label>.oraclevcn.com regardless of what
    # its private IP happens to be.
    hostname_label = local.node_hostname
  }

  # cloud-init metadata. `ssh_authorized_keys` is a well-known key that the
  # image's cloud-init reads on first boot and writes to
  # /home/ubuntu/.ssh/authorized_keys.
  #
  # This is the ONLY way into this machine. There is no password, and OCI
  # provides no password reset for a VM — recovery from a bad key here means
  # detaching the boot volume and attaching it to another instance.
  #
  # Nothing else is configured at boot on purpose. Cloud-init user-data is
  # imperative, unversioned and only ever runs once, which makes it a bad place
  # for configuration you will want to change. Everything past "can I SSH in"
  # belongs to `rehearsal`, where it is idempotent and re-runnable.
  metadata = {
    ssh_authorized_keys = local.ssh_public_key
  }

  # Delete the boot volume when the instance is terminated. The default is to
  # keep it, which sounds safe and is a trap on a free tier: orphaned boot
  # volumes silently consume the 200 GB grant, and a `terraform destroy` that
  # reports success while leaving 100 GB of storage behind is worse than one
  # that fails loudly.
  preserve_boot_volume = false

  freeform_tags = local.common_tags

  lifecycle {
    # ------------------------------------------------------------------------
    # The Always Free guardrail.
    #
    # A precondition is checked during PLAN, against the values that would
    # actually be used. Nothing is created and no API call is made if it fails.
    #
    # The full reasoning behind these numbers is in variables.tf under
    # `enforce_always_free`; the short version is that Oracle grants 1,500
    # OCPU-hours and 9,000 GB-hours a month, which is 2 OCPUs and 12 GB running
    # continuously — not the "4 and 24" figure that gets repeated everywhere.
    # ------------------------------------------------------------------------
    precondition {
      condition = !var.enforce_always_free || (
        var.instance_shape == "VM.Standard.A1.Flex" &&
        var.instance_ocpus <= 2 &&
        var.instance_memory_gbs <= 12 &&
        var.boot_volume_size_gbs <= 200
      )
      error_message = <<-EOT
        This configuration would exceed the Always Free continuous-use allowance.

        Requested : ${var.instance_ocpus} OCPU / ${var.instance_memory_gbs} GB RAM / ${var.boot_volume_size_gbs} GB boot volume
        Free 24/7 : 2 OCPU / 12 GB RAM / 200 GB total storage

        Oracle grants 1,500 OCPU-hours and 9,000 GB-hours per month on A1.
        Over a ~730-hour month that is 2.05 OCPUs and 12.3 GB running
        continuously. A 4 OCPU / 24 GB instance is creatable, but running it
        around the clock burns roughly double the grant and Oracle bills the
        difference.

        Either lower the numbers, or set enforce_always_free = false to accept
        the charges deliberately.
      EOT
    }

    # A second, unconditional check. If OCI's image catalogue returns nothing —
    # a typo in ubuntu_version, or a shape with no matching images — the
    # expression data.oci_core_images.ubuntu.images[0].id fails with an index
    # error that says nothing useful. This turns that into a sentence.
    precondition {
      condition     = length(data.oci_core_images.ubuntu.images) > 0
      error_message = "No Canonical Ubuntu ${var.ubuntu_version} image found for shape ${var.instance_shape} in this region. Check ubuntu_version against what OCI publishes (Console -> Compute -> Instances -> Create -> Change image)."
    }
  }

  timeouts {
    # OCI's default is 20 minutes. A1 provisioning in the free tier can be slow
    # when a region is busy, and a timeout here leaves a half-created instance
    # in state that has to be cleaned up by hand.
    create = "45m"
  }
}
