locals {
  subnets_by_name = { for subnet in var.subnets : subnet.name => subnet }

  firewall_rules_by_name = { for rule in var.firewall_rules : rule.name => rule }

  nat_count = var.nat_enabled ? 1 : 0
}
