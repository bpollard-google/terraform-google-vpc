variable "name" {
  description = "Name of the VPC network."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.name))
    error_message = "Network name must be 2-63 characters of lowercase letters, numbers and hyphens, starting with a letter."
  }
}

variable "project_id" {
  description = "ID of the project the network is created in."
  type        = string
}

variable "routing_mode" {
  description = "REGIONAL keeps routes within a region; GLOBAL propagates them across regions."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "GLOBAL"], var.routing_mode)
    error_message = "routing_mode must be REGIONAL or GLOBAL."
  }
}

variable "mtu" {
  description = "MTU of the network in bytes."
  type        = number
  default     = 1460
}

variable "subnets" {
  description = "Subnets created in the network."
  type = list(object({
    name                     = string
    ip_cidr_range            = string
    region                   = string
    private_ip_google_access = optional(bool, true)
    secondary_ranges = optional(list(object({
      range_name    = string
      ip_cidr_range = string
    })), [])
  }))
  default = []

  validation {
    condition     = length(distinct([for s in var.subnets : s.name])) == length(var.subnets)
    error_message = "Subnet names must be unique."
  }
}

variable "subnet_name_prefix" {
  description = "Prefix prepended to every subnet's name. Subnetwork names are unique per project and region rather than per network, so this lets the same configuration be applied twice in one project without colliding."
  type        = string
  default     = ""

  validation {
    condition     = var.subnet_name_prefix == "" || can(regex("^[a-z][a-z0-9-]*-$", var.subnet_name_prefix))
    error_message = "subnet_name_prefix must be empty, or lowercase letters, numbers and hyphens starting with a letter and ending with a hyphen."
  }
}

variable "nat_enabled" {
  description = "Whether a Cloud Router and Cloud NAT gateway are created."
  type        = bool
  default     = false
}

variable "nat_region" {
  description = "Region the Cloud Router and NAT gateway are created in. Required when nat_enabled is true."
  type        = string
  default     = null

  # Without this, nat_enabled = true and a null region plans cleanly and then
  # either fails at apply after the network and subnets already exist, or —
  # if the provider carries a default region — silently builds the router and
  # NAT in the wrong region, where NAT stops covering the subnets.
  validation {
    condition     = var.nat_enabled == false || var.nat_region != null
    error_message = "nat_region must be set when nat_enabled is true."
  }
}

variable "firewall_rules" {
  description = "Firewall rules applied to the network. All are allow rules."
  type = list(object({
    name          = string
    direction     = optional(string, "INGRESS")
    priority      = optional(number, 1000)
    source_ranges = optional(list(string), [])
    target_tags   = optional(list(string), [])
    protocol      = string
    ports         = optional(list(string), [])
  }))
  default = []

  validation {
    condition     = length(distinct([for r in var.firewall_rules : r.name])) == length(var.firewall_rules)
    error_message = "Firewall rule names must be unique."
  }

  # The module renders no destination_ranges, so an EGRESS rule cannot be
  # expressed correctly here. Rejecting it also keeps the source_ranges rule
  # below unconditional: were EGRESS allowed through, a rule carrying no
  # source_ranges would be one hardcoded `direction` away from becoming a
  # world-open INGRESS rule.
  validation {
    condition     = alltrue([for r in var.firewall_rules : r.direction == "INGRESS"])
    error_message = "direction must be INGRESS; EGRESS rules are unsupported because this module exposes no destination_ranges."
  }

  # GCP reads an INGRESS rule with no sourceRanges as 0.0.0.0/0, so an empty
  # list is not "no sources" — it is the whole internet. Checkov does not
  # catch this, because there is no 0.0.0.0/0 literal for it to match.
  # Deliberately unconditional: see the EGRESS rule above before adding a
  # direction guard here.
  validation {
    condition     = alltrue([for r in var.firewall_rules : length(r.source_ranges) > 0])
    error_message = "source_ranges must be non-empty; GCP treats an empty list on an INGRESS rule as 0.0.0.0/0."
  }

  # Every source range must be CIDR notation. This is required by GCP anyway,
  # but validating it here also means the prefix-width rule below can parse a
  # prefix without a bare `10.0.0.0` blowing up on a missing list index — that
  # rule falls back to /128, and this rule owns the error message.
  validation {
    condition = alltrue([
      for r in var.firewall_rules :
      alltrue([for c in r.source_ranges : can(cidrsubnet(c, 0, 0))])
    ])
    error_message = "Every source_ranges entry must be CIDR notation, for example 10.0.0.0/8 or 0.0.0.0/0."
  }

  # `all` subsumes tcp, udp and sctp and cannot carry ports, so the ports rule
  # below can never constrain it by construction — `protocol = "all"` is
  # strictly broader than anything that rule rejects. It is refused outright
  # rather than special-cased: the module renders one allow block per rule, so
  # a caller who genuinely wants several protocols writes several rules and
  # says which. Unlike tcp/udp/sctp this is a keyword with no IANA number
  # (protocol 0 is HOPOPT, not "all"), so normalising case and whitespace is
  # the whole of the spelling axis.
  validation {
    condition     = alltrue([for r in var.firewall_rules : trimspace(lower(r.protocol)) != "all"])
    error_message = "protocol must not be 'all'; write one rule per protocol so the ports rule can constrain each."
  }

  # An allow entry with no ports opens every port of that protocol. Only tcp,
  # udp and sctp carry ports; icmp, esp, ah and ipip must omit them, so they
  # are exempt by necessity rather than by choice.
  #
  # GCP documents IPProtocol as a well-known name *or* the protocol number, so
  # the same protocol has many spellings: "tcp", " TCP ", "6", "006". Matching
  # the number numerically rather than as a string closes that axis instead of
  # enumerating it — tonumber collapses whitespace and leading zeroes, and the
  # -1 fallback means a name simply fails the numeric test.
  validation {
    condition = alltrue([
      for r in var.firewall_rules : length(r.ports) > 0
      if contains(["tcp", "udp", "sctp"], trimspace(lower(r.protocol)))
      || contains([6, 17, 132], try(tonumber(trimspace(r.protocol)), -1))
    ])
    error_message = "ports must be non-empty for tcp, udp and sctp rules, named or numbered; GCP treats an empty list as every port."
  }

  # A rule from a wide source applied to no tags is "the internet to every VM
  # in the network" — the shape Checkov misses outside its hardcoded
  # well-known-port list.
  #
  # Width is measured by prefix length rather than by matching any-source
  # literals, so this covers 0.0.0.0/0, the IPv6 ::/0 that Checkov does not
  # recognise at all, and the 0.0.0.0/1 + 128.0.0.0/1 split that evades any
  # literal list. The floor is strictly below /8, not /8 or wider: 10.0.0.0/8
  # is the canonical RFC1918 internal source and untagged internal rules are a
  # normal pattern that must keep working.
  #
  # This is a floor, not proof of containment. Enough narrow public blocks
  # still add up to the internet; HCL cannot express real CIDR arithmetic.
  validation {
    condition = alltrue([
      for r in var.firewall_rules : length(r.target_tags) > 0
      if anytrue([for c in r.source_ranges : try(tonumber(split("/", c)[1]), 128) < 8])
    ])
    error_message = "target_tags must be non-empty when any source_ranges entry is broader than /8 (including 0.0.0.0/0 and ::/0); an untagged rule applies to every instance in the network."
  }
}
