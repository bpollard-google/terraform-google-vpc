mock_provider "google" {}

variables {
  name       = "serviceops-demo-vpc"
  project_id = "demo-project"
}

run "defaults_are_safe" {
  command = plan

  assert {
    condition     = google_compute_network.this.name == "serviceops-demo-vpc"
    error_message = "Network name should pass through unchanged."
  }

  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "Auto-created subnetworks must be disabled; subnets are declared explicitly."
  }

  assert {
    condition     = google_compute_network.this.routing_mode == "REGIONAL"
    error_message = "Default routing mode should be REGIONAL."
  }

  assert {
    condition     = length(google_compute_subnetwork.this) == 0
    error_message = "No subnets should be created by default."
  }

  assert {
    condition     = length(google_compute_router_nat.this) == 0
    error_message = "Cloud NAT should be off by default."
  }

  assert {
    condition     = google_compute_network.this.mtu == 1460
    error_message = "Default MTU should be 1460."
  }
}

run "mtu_is_configurable" {
  command = plan
  variables {
    mtu = 8896
  }

  assert {
    condition     = google_compute_network.this.mtu == 8896
    error_message = "MTU should pass through unchanged."
  }
}

run "routing_mode_is_configurable" {
  command = plan
  variables {
    routing_mode = "GLOBAL"
  }

  assert {
    condition     = google_compute_network.this.routing_mode == "GLOBAL"
    error_message = "routing_mode should pass through unchanged."
  }
}

run "rejects_unknown_routing_mode" {
  command = plan
  variables {
    routing_mode = "PLANETARY"
  }
  expect_failures = [var.routing_mode]
}

run "rejects_invalid_name" {
  command = plan
  variables {
    name = "Invalid_VPC"
  }
  expect_failures = [var.name]
}

run "rejects_nat_enabled_without_a_region" {
  command = plan
  variables {
    nat_enabled = true
    nat_region  = null
  }
  expect_failures = [var.nat_region]
}

# GCP reads an INGRESS rule with no sourceRanges as 0.0.0.0/0 and an allow
# entry with no ports as every port, so this rule — the minimum the type
# system alone would accept — is "the whole internet to every TCP port on
# every VM". Checkov passes it clean. The module must not.
run "rejects_ingress_rule_with_no_source_ranges" {
  command = plan
  variables {
    firewall_rules = [
      { name = "bare-minimum", protocol = "tcp", ports = ["443"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_port_bearing_rule_with_no_ports" {
  command = plan
  variables {
    firewall_rules = [
      { name = "all-ports", protocol = "tcp", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_the_bare_minimum_rule" {
  command = plan
  variables {
    firewall_rules = [
      { name = "bare-minimum", protocol = "tcp" },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# protocol = "6" is TCP by IANA number. GCP accepts it, so spelling the ports
# rule by name alone would let it through as TCP on every port.
run "rejects_numeric_tcp_protocol_with_no_ports" {
  command = plan
  variables {
    firewall_rules = [
      { name = "numeric-tcp", protocol = "6", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_numeric_udp_protocol_with_no_ports" {
  command = plan
  variables {
    firewall_rules = [
      { name = "numeric-udp", protocol = "17", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# Hardcoding direction in main.tf would otherwise turn a caller's EGRESS rule
# into a world-open INGRESS rule, since EGRESS carries no source_ranges.
run "rejects_egress_rules" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "egress-443"
        direction     = "EGRESS"
        protocol      = "tcp"
        ports         = ["443"]
        source_ranges = ["10.0.0.0/8"]
      },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# GCP documents IPProtocol as a name or a number, so the same protocol has
# several spellings. These are the ones a string allowlist misses.
run "rejects_padded_numeric_protocol_with_no_ports" {
  command = plan
  variables {
    firewall_rules = [
      { name = "padded-tcp", protocol = "006", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_whitespace_padded_protocol_with_no_ports" {
  command = plan
  variables {
    firewall_rules = [
      { name = "spaced-tcp", protocol = " tcp ", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# `all` subsumes tcp/udp/sctp and cannot carry ports, so the ports rule can
# never constrain it. It is refused outright.
run "rejects_protocol_all" {
  command = plan
  variables {
    firewall_rules = [
      { name = "everything", protocol = "all", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_protocol_all_in_any_spelling" {
  command = plan
  variables {
    firewall_rules = [
      { name = "everything", protocol = " ALL ", source_ranges = ["10.0.0.0/8"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_malformed_source_range" {
  command = plan
  variables {
    firewall_rules = [
      { name = "no-prefix", protocol = "tcp", ports = ["443"], source_ranges = ["10.0.0.0"] },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# The IPv6 any-source literal. Checkov does not recognise ::/0 at all, so
# nothing else catches this.
run "rejects_ipv6_any_source_with_no_target_tags" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "v6-open"
        protocol      = "tcp"
        ports         = ["22"]
        source_ranges = ["::/0"]
      },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# Two halves of the IPv4 space cover the internet without ever writing
# 0.0.0.0/0, which is why width is measured by prefix rather than by literal.
run "rejects_split_cidr_covering_the_internet" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "split-open"
        protocol      = "tcp"
        ports         = ["8000-8999"]
        source_ranges = ["0.0.0.0/1", "128.0.0.0/1"]
      },
    ]
  }
  expect_failures = [var.firewall_rules]
}

run "rejects_internet_wide_rule_with_no_target_tags" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "world-open"
        protocol      = "tcp"
        ports         = ["8000-8999"]
        source_ranges = ["0.0.0.0/0"]
      },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# The same rule scoped with a tag is allowed: this is how a public load
# balancer backend is expressed.
run "accepts_internet_wide_rule_with_target_tags" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "public-lb"
        protocol      = "tcp"
        ports         = ["443"]
        source_ranges = ["0.0.0.0/0"]
        target_tags   = ["public-lb"]
      },
    ]
  }

  assert {
    condition     = google_compute_firewall.this["public-lb"].target_tags == toset(["public-lb"])
    error_message = "A tagged internet-facing rule should be accepted."
  }
}

# The floor sits strictly below /8, so /7 is rejected and the /8 below is
# allowed. This pair pins the boundary; 10.0.0.0/8 must keep working because
# untagged internal rules are a normal pattern.
run "rejects_untagged_rule_from_a_slash_seven_source" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "too-wide"
        protocol      = "tcp"
        ports         = ["443"]
        source_ranges = ["10.0.0.0/7"]
      },
    ]
  }
  expect_failures = [var.firewall_rules]
}

# An untagged rule from an RFC1918 source stays allowed.
run "accepts_untagged_rule_from_private_source" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "allow-internal"
        protocol      = "tcp"
        ports         = ["443"]
        source_ranges = ["10.0.0.0/8"]
      },
    ]
  }

  assert {
    condition     = length(google_compute_firewall.this["allow-internal"].target_tags) == 0
    error_message = "An untagged rule from a private source should be accepted."
  }
}

# Validation normalises the protocol before matching, so rendering must
# normalise too — otherwise " TCP " passes validation and GCP rejects the
# plan at apply.
run "protocol_is_rendered_normalised" {
  command = plan
  variables {
    firewall_rules = [
      {
        name          = "padded"
        protocol      = " TCP "
        ports         = ["443"]
        source_ranges = ["10.0.0.0/8"]
      },
    ]
  }

  assert {
    condition     = one(google_compute_firewall.this["padded"].allow).protocol == "tcp"
    error_message = "Protocol should be rendered in the normalised form validation accepts."
  }
}

# icmp carries no ports, so the ports rule must not demand them.
run "accepts_icmp_rule_without_ports" {
  command = plan
  variables {
    firewall_rules = [
      { name = "allow-icmp", protocol = "icmp", source_ranges = ["10.0.0.0/8"] },
    ]
  }

  assert {
    condition     = one(google_compute_firewall.this["allow-icmp"].allow).protocol == "icmp"
    error_message = "An icmp rule with no ports should be accepted."
  }
}
