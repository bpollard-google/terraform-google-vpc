# Minimal usage: a custom-mode network with a single subnet.

# The project is a variable rather than a literal so the nightly real-GCP
# tiers can plan and apply this example against the sandbox project. The
# mock-provider tests ignore the value entirely.
variable "project_id" {
  description = "Project the example resources are created in."
  type        = string
  default     = "serviceops-demo"
}

variable "name_suffix" {
  description = "Suffix appended to resource names so concurrent CI runs do not collide."
  type        = string
  default     = ""
}

module "network" {
  source = "../../"

  name       = "serviceops-example-basic${var.name_suffix == "" ? "" : "-${var.name_suffix}"}"
  project_id = var.project_id

  # Subnets are prefixed rather than suffixed, and via a module variable rather
  # than inline in the subnet's name. Checkov can only resolve a for_each key
  # that is a string literal, and the module keys subnets by name, so making the
  # name expression dynamic here would collapse the address from
  # google_compute_subnetwork.this["app"] to an unkeyed
  # google_compute_subnetwork.this — missing the CKV_GCP_26 baseline entry and
  # failing CKV_GCP_74 against a subnet that sets private_ip_google_access
  # correctly. Prefixing in the module leaves the key literal and the address
  # stable.
  subnet_name_prefix = var.name_suffix == "" ? "" : "${var.name_suffix}-"

  subnets = [
    # private_ip_google_access is already the module default. It is restated
    # here because a value that arrives only from an optional(...) default is
    # invisible to Checkov, which then fails CKV_GCP_74 against a subnet that
    # is configured correctly. Both examples name their subnet "app", so the
    # two share a resource address and baselining the false positive would
    # suppress the check for the complete example too.
    {
      name                     = "app"
      ip_cidr_range            = "10.0.0.0/20"
      region                   = "europe-west2"
      private_ip_google_access = true
    },
  ]
}

output "network_self_link" {
  description = "URI of the created network."
  value       = module.network.network_self_link
}

# Names rather than self_links, for two reasons. The nightly tier-3 assertion
# needs to see the subnet — it is the resource that actually collides between
# runs, since subnetwork names are unique per project and region rather than per
# network, and until now only the network appeared in an output. And a name is
# a configured attribute, so it is known at plan time and the tests can assert
# on it; a self_link is computed, so under a mock provider its value tells you
# nothing.
output "network_name" {
  description = "Name of the created network."
  value       = module.network.network_name
}

output "subnet_names" {
  description = "Map of subnet key to the name actually created."
  value       = module.network.subnet_names
}
