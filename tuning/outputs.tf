# =============================================================================
# tuning / outputs.tf — the handoff to rehearsal
# =============================================================================
#
# Outputs are the layer's public interface. Everything above this line is
# tuning's private business; what a later layer needs to know is only what
# appears here.
#
# That framing matters for the whole platform. `rehearsal` should not care that
# the IP came from an OCI VNIC attached to a regional subnet — it needs a host
# to reach and a user to log in as. Keeping the boundary narrow is what would
# let this layer be swapped for Hetzner or a bare-metal box without touching a
# line of Ansible.
#
# Read them with:
#   terraform output                    # all of them, human-readable
#   terraform output -raw node_public_ip  # one value, no quotes, for scripting
# =============================================================================


output "node_public_ip" {
  description = "Public IPv4 address of the node. This is the address rehearsal, kubectl and ArgoCD all talk to."
  value       = oci_core_instance.podium.public_ip
}

output "node_private_ip" {
  description = "Private IP inside the VCN. K3s binds its internal networking to this, and it is what a second node would use to join the cluster."
  value       = oci_core_instance.podium.private_ip
}

output "node_internal_fqdn" {
  description = <<-EOT
    The node's name in the VCN's internal DNS. Stable across instance restarts
    in a way the private IP is not, so anything internal that needs to find
    this host should prefer the name.
  EOT
  value       = "${local.node_hostname}.${oci_core_subnet.pit.dns_label}.${oci_core_vcn.stage.dns_label}.oraclevcn.com"
}

output "instance_ocid" {
  description = "OCID of the instance — what you need for any OCI CLI or console operation against it."
  value       = oci_core_instance.podium.id
}

output "availability_domain" {
  description = "Which availability domain the instance actually landed in. Worth recording: if a rebuild hits a capacity error, this is the AD to stop trying."
  value       = oci_core_instance.podium.availability_domain
}

output "image_used" {
  description = "Display name of the Ubuntu image this node was built from. The image is resolved as 'newest available' at apply time, so this is the only record of which one you actually got."
  value       = data.oci_core_images.ubuntu.images[0].display_name
}

output "ssh_command" {
  description = "Copy-paste command to reach the node. The default user on OCI's Ubuntu images is 'ubuntu' — not 'root', and not 'opc' (that one is Oracle Linux)."
  value       = "ssh ubuntu@${oci_core_instance.podium.public_ip}"
}

output "kube_api_endpoint" {
  description = "Where the K3s API server will listen once rehearsal installs it. Nothing answers here yet — this is the address layer 2 makes real and layer 4 connects to."
  value       = "https://${oci_core_instance.podium.public_ip}:6443"
}

output "free_tier_usage" {
  description = <<-EOT
    What this instance consumes against the Always Free grant, computed from
    the values actually applied. Printed so the answer to "am I still inside
    the free tier?" is a command rather than a memory.
  EOT
  value = {
    ocpus_used              = var.instance_ocpus
    ocpus_free_continuous   = 2
    memory_gb_used          = var.instance_memory_gbs
    memory_gb_free_cont     = 12
    storage_gb_used         = var.boot_volume_size_gbs
    storage_gb_free_total   = 200
    monthly_ocpu_hours      = var.instance_ocpus * 730
    monthly_ocpu_hours_free = 1500
    monthly_gb_hours        = var.instance_memory_gbs * 730
    monthly_gb_hours_free   = 9000
    within_free_tier = (
      var.instance_ocpus * 730 <= 1500 &&
      var.instance_memory_gbs * 730 <= 9000 &&
      var.boot_volume_size_gbs <= 200
    )
  }
}

output "ansible_inventory" {
  description = <<-EOT
    A ready-to-use Ansible inventory for `rehearsal` (layer 2).

    This is the actual seam between the two layers. Rather than have Ansible
    query OCI itself — which would mean a second set of cloud credentials and a
    dynamic inventory plugin to install and debug — tuning simply states the
    facts it already knows, and rehearsal consumes plain text. Terraform owns
    what exists; Ansible owns what is configured on it. Neither reaches into
    the other.

    Write it out after apply:

      terraform output -raw ansible_inventory > ../rehearsal/inventory.ini

    That file is gitignored (it carries the live IP and your key path); the
    committed template is rehearsal/inventory.example.ini.

    Note the key path below is emitted VERBATIM rather than expanded to an
    absolute path. That is deliberate. Terraform can legitimately be run from
    PowerShell while Ansible runs inside WSL, and an absolute path resolved on
    the Windows side ("C:\\Users\\me\\.ssh\\key") is meaningless to WSL.
    Leaving "~/..." alone lets Ansible expand it in whichever environment it
    actually runs, so the inventory is correct either way.
  EOT
  value       = <<-EOT
    # Generated by tuning (Terraform). Do not edit by hand — regenerate with:
    #   cd tuning && terraform output -raw ansible_inventory > ../rehearsal/inventory.ini

    [ensemble]
    podium ansible_host=${oci_core_instance.podium.public_ip}

    [ensemble:vars]
    ansible_user=ubuntu
    ansible_python_interpreter=/usr/bin/python3
    ansible_ssh_private_key_file=${trimsuffix(var.ssh_public_key_path, ".pub")}

    # Facts tuning knows and rehearsal would otherwise have to rediscover.
    node_private_ip=${oci_core_instance.podium.private_ip}
    node_public_ip=${oci_core_instance.podium.public_ip}
    vcn_cidr=${var.vcn_cidr}
  EOT
}
