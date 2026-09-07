resource "google_compute_network" "this" {
  name                    = var.name
  project                 = var.project_id
  routing_mode            = var.routing_mode
  mtu                     = var.mtu
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  for_each = local.subnets_by_name

  # The prefix is applied to the rendered name only, never to the for_each key.
  # Subnetwork names are unique per project and region rather than per network,
  # so a caller running the same configuration twice in one project needs a way
  # to keep them apart; keying on the unprefixed name keeps the resource address
  # stable while the prefix varies.
  name                     = "${var.subnet_name_prefix}${each.value.name}"
  project                  = var.project_id
  network                  = google_compute_network.this.id
  ip_cidr_range            = each.value.ip_cidr_range
  region                   = each.value.region
  private_ip_google_access = each.value.private_ip_google_access

  dynamic "secondary_ip_range" {
    for_each = each.value.secondary_ranges

    content {
      range_name    = secondary_ip_range.value.range_name
      ip_cidr_range = secondary_ip_range.value.ip_cidr_range
    }
  }
}

resource "google_compute_router" "this" {
  count = local.nat_count

  name    = "${var.name}-router"
  project = var.project_id
  network = google_compute_network.this.id
  region  = var.nat_region
}

resource "google_compute_router_nat" "this" {
  count = local.nat_count

  name                               = "${var.name}-nat"
  project                            = var.project_id
  router                             = google_compute_router.this[0].name
  region                             = var.nat_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "this" {
  for_each = local.firewall_rules_by_name

  name    = each.value.name
  project = var.project_id
  network = google_compute_network.this.id
  # Only ever "INGRESS" — variables.tf rejects EGRESS. Do not hardcode this:
  # if EGRESS support is added, a literal here turns a caller's EGRESS rule
  # into a world-open INGRESS rule, since EGRESS carries no source_ranges.
  direction     = each.value.direction
  priority      = each.value.priority
  source_ranges = each.value.source_ranges
  target_tags   = each.value.target_tags

  allow {
    # Normalised the same way variables.tf validates it, so the two agree.
    # Rendering raw would let " tcp " pass validation and then be rejected by
    # GCP at apply.
    protocol = trimspace(lower(each.value.protocol))
    ports    = each.value.ports
  }
}
