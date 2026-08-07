# =============================================================================
# tuning / versions.tf — what Terraform is, and what it's allowed to talk to
# =============================================================================
#
# Every Terraform directory ("root module") needs to answer two questions before
# it can do anything:
#
#   1. Which version of Terraform itself is this written for?
#   2. Which *providers* — the plugins that know how to call a real API — does
#      it need, and at what versions?
#
# Terraform core knows nothing about Oracle Cloud. It is a graph engine: it
# reads .tf files, works out what depends on what, and calls plugins to do the
# actual work. The `oracle/oci` provider is the plugin that turns
# `resource "oci_core_instance"` into REST calls against Oracle's API.
# =============================================================================

terraform {
  # 1.9 is the floor because this config uses cross-variable `validation`
  # blocks (a validation rule that reads *another* variable), which landed in
  # Terraform 1.9. See variables.tf — it's what lets the free-tier guardrails
  # live in code instead of in a README nobody reads.
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source = "oracle/oci"

      # `~> 8.0` means "any 8.x, but never 9.x".
      #
      # The reasoning: a provider's major version is where breaking changes
      # land. Pinning the major means `terraform init` on a fresh clone picks
      # up bug fixes and new attributes automatically, but a future 9.0 that
      # renames arguments can't silently break this config at the worst
      # possible moment.
      #
      # The *exact* versions actually used are recorded in
      # .terraform.lock.hcl, which IS committed. That file — not this line —
      # is what makes a clone reproducible: it stores the resolved version
      # plus checksums for each platform. This line sets the allowed range;
      # the lockfile pins the specific point inside it.
      version = "~> 8.0"
    }
  }

  # ---------------------------------------------------------------------------
  # STATE — read this before you run anything
  # ---------------------------------------------------------------------------
  #
  # Terraform keeps a JSON file mapping every resource in this config to the
  # real object it created ("oci_core_instance.podium is instance ocid1.xyz").
  # That map is state, and it's what lets Terraform tell the difference between
  # "create this" and "this already exists, leave it alone."
  #
  # There is no `backend` block here, so state is LOCAL: terraform.tfstate in
  # this directory. That is a deliberate choice for this repo, not an oversight:
  #
  #   - One operator (me), one machine, one instance. The problems remote state
  #     solves — two engineers applying at once and corrupting each other's
  #     view, or a laptop dying with the only copy of the map — don't exist yet.
  #   - Remote state on OCI means an Object Storage bucket that has to be
  #     created *before* Terraform runs, which is a bootstrapping problem
  #     ("who terraforms the terraform bucket?") that adds real complexity for
  #     zero benefit at this size.
  #
  # What changes when a second person shows up: state stops being a file and
  # becomes shared infrastructure that needs locking. On OCI you'd use the S3-
  # compatible endpoint that Object Storage exposes:
  #
  #   terraform {
  #     backend "s3" {
  #       bucket   = "ensemble-tfstate"
  #       key      = "tuning/terraform.tfstate"
  #       region   = "sa-saopaulo-1"
  #       endpoints = {
  #         s3 = "https://<namespace>.compat.objectstorage.sa-saopaulo-1.oraclecloud.com"
  #       }
  #       use_lockfile = true   # object-storage-based locking, no DynamoDB
  #
  #       # OCI's S3 compatibility layer is close but not identical to AWS,
  #       # so the AWS-specific preflight calls have to be switched off:
  #       skip_region_validation      = true
  #       skip_credentials_validation = true
  #       skip_requesting_account_id  = true
  #       skip_metadata_api_check     = true
  #       skip_s3_checksum            = true
  #     }
  #   }
  #
  # The credentials for that are a Customer Secret Key generated against your
  # OCI user — an access key / secret pair, distinct from the API signing key
  # this provider uses. They'd go in env vars, never in this file.
  #
  # Either way: state is not a backup and not documentation. It is a live index
  # that can contain secrets in plaintext. See .gitignore — it is never
  # committed.
  # ---------------------------------------------------------------------------
}

# =============================================================================
# Provider configuration — how Terraform proves it's allowed to do this
# =============================================================================
#
# OCI does not use a bearer token. Every API request is *signed* with an RSA
# private key, and Oracle verifies the signature against the matching public
# key you uploaded to your user profile. Four pieces identify the caller:
#
#   tenancy OCID  — which Oracle Cloud account
#   user OCID     — which user inside it
#   fingerprint   — which of that user's uploaded keys signed this
#   private key   — the key doing the signing (never leaves the machine)
#
# Those four normally live in ~/.oci/config, grouped into named profiles. That
# is the default here: the provider reads the file, so no credential value ever
# appears in this repo — not in a .tf file, not in a .tfvars file, not in a
# shell history entry.
#
# See tuning/README.md for how to generate the key and write that file.
# =============================================================================

provider "oci" {
  # "ApiKey" is the config-file / signing-key flow described above.
  #
  # The alternatives, worth knowing for later:
  #   "SecurityToken"     — short-lived session from `oci session authenticate`,
  #                         good for humans, expires in an hour.
  #   "InstancePrincipal" — an OCI VM authenticating *as itself* via its
  #                         instance identity, no key on disk at all. This is
  #                         what you'd use if `score` ever ran Terraform from
  #                         inside OCI.
  auth = var.oci_auth

  # Which profile inside ~/.oci/config. "DEFAULT" unless you juggle tenancies.
  config_file_profile = var.oci_config_profile

  # Null means "use whatever region the profile specifies". Setting it here
  # overrides the profile, which is handy for deploying the same config to a
  # second region without editing your OCI config.
  region = var.region
}
