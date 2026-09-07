# Full usage: multiple subnets with secondary ranges, Cloud NAT and firewall rules.

# The project is a variable rather than a literal so the nightly real-GCP
# tiers can plan and apply this example against the sandbox project. The
# mock-provider tests ignore the value entirely.
variable "project_id" {
  description = "Project the example resources are created in."
  type        = string
  default     = "serviceops-demo"
}

module "network" {
  source = "../../"

  name         = "serviceops-example-complete"
  project_id   = var.project_id
  routing_mode = "GLOBAL"

  subnets = [
    # private_ip_google_access defaults to true, but it is passed explicitly
    # here: a value supplied only by an optional(...) type default is invisible
    # to Checkov, which then reports CKV_GCP_74 against a subnet that is in
    # fact configured correctly. Passing it at the call site is what makes the
    # check resolve, and is cheaper than baselining a false positive.
    {
      name                     = "app"
      ip_cidr_range            = "10.0.0.0/20"
      region                   = "europe-west2"
      private_ip_google_access = true
      secondary_ranges = [
        { range_name = "pods", ip_cidr_range = "10.4.0.0/14" },
        { range_name = "services", ip_cidr_range = "10.8.0.0/20" },
      ]
    },
    {
      name                     = "data"
      ip_cidr_range            = "10.0.16.0/20"
      region                   = "europe-west2"
      private_ip_google_access = true
    },
  ]

  nat_enabled = true
  nat_region  = "europe-west2"

  firewall_rules = [
    {
      name          = "allow-internal"
      source_ranges = ["10.0.0.0/8"]
      protocol      = "tcp"
      ports         = ["0-65535"]
    },
    {
      name          = "allow-health-checks"
      priority      = 900
      source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
      target_tags   = ["lb-backend"]
      protocol      = "tcp"
      ports         = ["8080"]
    },
  ]
}

output "network_self_link" {
  description = "URI of the created network."
  value       = module.network.network_self_link
}

output "subnet_self_links" {
  description = "Map of subnet name to subnet URI."
  value       = module.network.subnet_self_links
}
