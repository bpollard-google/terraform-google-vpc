mock_provider "google" {}

variables {
  name       = "serviceops-demo-vpc"
  project_id = "demo-project"
}

run "subnets_are_created_with_secondary_ranges" {
  command = plan

  variables {
    subnets = [
      {
        name          = "app"
        ip_cidr_range = "10.0.0.0/20"
        region        = "europe-west2"
        secondary_ranges = [
          { range_name = "pods", ip_cidr_range = "10.4.0.0/14" },
          { range_name = "services", ip_cidr_range = "10.8.0.0/20" },
        ]
      },
      {
        name          = "data"
        ip_cidr_range = "10.0.16.0/20"
        region        = "europe-west2"
      },
      # The documented per-subnet opt-out. Nothing else passes this as false,
      # so without this entry a static `true` in main.tf would keep every
      # test green while silently deleting the opt-out.
      {
        name                     = "isolated"
        ip_cidr_range            = "10.0.32.0/20"
        region                   = "europe-west1"
        private_ip_google_access = false
      },
    ]
  }

  assert {
    condition     = length(google_compute_subnetwork.this) == 3
    error_message = "One subnetwork should be created per entry."
  }

  assert {
    condition     = google_compute_subnetwork.this["app"].ip_cidr_range == "10.0.0.0/20"
    error_message = "Subnet CIDR should pass through unchanged."
  }

  assert {
    condition     = length(google_compute_subnetwork.this["app"].secondary_ip_range) == 2
    error_message = "Both secondary ranges should be rendered."
  }

  assert {
    condition     = length(google_compute_subnetwork.this["data"].secondary_ip_range) == 0
    error_message = "A subnet with no secondary ranges should render none."
  }

  assert {
    condition     = google_compute_subnetwork.this["app"].private_ip_google_access == true
    error_message = "Private Google access should default to true."
  }

  assert {
    condition     = google_compute_subnetwork.this["isolated"].private_ip_google_access == false
    error_message = "The per-subnet Private Google Access opt-out should be honoured."
  }

  assert {
    condition     = google_compute_subnetwork.this["isolated"].region == "europe-west1"
    error_message = "Subnet region should pass through unchanged."
  }
}

run "nat_is_created_when_enabled" {
  command = plan

  variables {
    nat_enabled = true
    nat_region  = "europe-west2"
  }

  assert {
    condition     = length(google_compute_router.this) == 1
    error_message = "Enabling NAT should create exactly one router."
  }

  assert {
    condition     = length(google_compute_router_nat.this) == 1
    error_message = "Enabling NAT should create exactly one NAT gateway."
  }

  assert {
    condition     = google_compute_router_nat.this[0].source_subnetwork_ip_ranges_to_nat == "ALL_SUBNETWORKS_ALL_IP_RANGES"
    error_message = "NAT should cover all subnetwork ranges."
  }

  assert {
    condition     = google_compute_router.this[0].region == "europe-west2"
    error_message = "The router should be created in nat_region."
  }

  # log_config on google_compute_router_nat is a list-nested block, max 1.
  assert {
    condition     = google_compute_router_nat.this[0].log_config[0].enable == true
    error_message = "NAT logging should be enabled."
  }
}

run "firewall_rules_are_created" {
  command = plan

  variables {
    firewall_rules = [
      {
        name          = "allow-internal"
        direction     = "INGRESS"
        priority      = 1000
        source_ranges = ["10.0.0.0/8"]
        protocol      = "tcp"
        ports         = ["0-65535"]
      },
      {
        name          = "allow-health-checks"
        direction     = "INGRESS"
        priority      = 900
        source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
        target_tags   = ["lb-backend"]
        protocol      = "tcp"
        ports         = ["8080"]
      },
    ]
  }

  assert {
    condition     = length(google_compute_firewall.this) == 2
    error_message = "One firewall resource should be created per rule."
  }

  assert {
    condition     = google_compute_firewall.this["allow-internal"].priority == 1000
    error_message = "Firewall priority should pass through unchanged."
  }

  # `allow` is a set-nested block, so `[0]` is a hard "Cannot index a set
  # value" error. The module renders exactly one allow block per rule, so
  # `one(...)` is both legal and a stronger assertion. `ports` inside it is
  # a genuine list, so `[0]` there is fine.
  assert {
    condition     = one(google_compute_firewall.this["allow-health-checks"].allow).ports[0] == "8080"
    error_message = "Firewall ports should pass through unchanged."
  }

  assert {
    condition     = one(google_compute_firewall.this["allow-internal"].allow).protocol == "tcp"
    error_message = "Firewall protocol should pass through unchanged."
  }

  assert {
    condition     = google_compute_firewall.this["allow-internal"].source_ranges == toset(["10.0.0.0/8"])
    error_message = "Firewall source ranges should pass through unchanged."
  }

  assert {
    condition     = google_compute_firewall.this["allow-health-checks"].source_ranges == toset(["35.191.0.0/16", "130.211.0.0/22"])
    error_message = "All source ranges should reach the rule."
  }

  assert {
    condition     = google_compute_firewall.this["allow-health-checks"].target_tags == toset(["lb-backend"])
    error_message = "Firewall target tags should pass through unchanged."
  }

  assert {
    condition     = google_compute_firewall.this["allow-health-checks"].direction == "INGRESS"
    error_message = "Firewall direction should pass through unchanged."
  }

  assert {
    condition     = google_compute_firewall.this["allow-health-checks"].priority == 900
    error_message = "A non-default priority should pass through unchanged."
  }
}

# Subnetwork names are unique per project and region rather than per network, so
# suffixing the network alone does not stop two runs of the same configuration
# from colliding. The prefix is what actually separates them.
run "subnet_name_prefix_is_applied_to_the_rendered_name" {
  command = plan

  variables {
    subnet_name_prefix = "ci12345-"
    subnets = [
      { name = "app", ip_cidr_range = "10.0.0.0/20", region = "europe-west2" },
    ]
  }

  # Indexing by the unprefixed key is itself the assertion that the prefix never
  # reaches the for_each key: this lookup fails outright if the key moved. That
  # is not cosmetic. Checkov can only resolve a for_each key that is a string
  # literal, so a dynamic key collapses the address to an unkeyed resource,
  # losing the CKV_GCP_26 baseline entry and failing CKV_GCP_74 against a subnet
  # that sets private_ip_google_access correctly.
  assert {
    condition     = google_compute_subnetwork.this["app"].name == "ci12345-app"
    error_message = "expected the prefix on the rendered name, got ${google_compute_subnetwork.this["app"].name}"
  }
}

# The empty default is the module's backward-compatibility promise: every caller
# that predates this variable must render exactly the name it rendered before.
run "subnet_name_prefix_defaults_to_leaving_the_name_alone" {
  command = plan

  variables {
    subnets = [
      { name = "app", ip_cidr_range = "10.0.0.0/20", region = "europe-west2" },
    ]
  }

  assert {
    condition     = google_compute_subnetwork.this["app"].name == "app"
    error_message = "an unset prefix must leave the name untouched, got ${google_compute_subnetwork.this["app"].name}"
  }
}
