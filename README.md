# terraform-google-vpc

A custom-mode VPC network with explicit subnets, optional Cloud NAT and
optional firewall rules. Auto-mode subnet creation is always disabled.

## Usage

```hcl
module "network" {
  source = "github.com/YOUR_ORG/terraform-google-vpc?ref=v1.0.0"

  name       = "my-vpc"
  project_id = "my-project"

  subnets = [
    {
      name          = "app"
      ip_cidr_range = "10.0.0.0/20"
      region        = "europe-west2"
    },
  ]
}
```

See [`examples/basic`](examples/basic) for the minimum, and
[`examples/complete`](examples/complete) for every option.

## Subnets

Every subnet gets Private Google Access by default, so workloads without
external IPs can still reach Google APIs. Set `private_ip_google_access` to
false per subnet to opt out.

Both examples restate `private_ip_google_access = true` even though it is the
default. That is deliberate — see [Security scanning](#security-scanning).

Secondary ranges are declared inline per subnet, which is what GKE needs for
pod and service ranges.

VPC Flow Logs are not supported. The module owns the subnet and exposes no
`log_config`, so they cannot be enabled by a caller; adding them needs a
change request against this module.

## Cloud NAT

Setting `nat_enabled` to true creates one Cloud Router and one NAT gateway in
`nat_region`, covering all subnetwork ranges. `nat_region` is required when
`nat_enabled` is true, and a validation rule enforces it: without that, a null
region either fails at apply once the network and subnets already exist, or —
where the provider carries a default region — silently builds the router and
NAT somewhere else, so NAT stops covering the subnets.

## Firewall rules

All rules are allow rules. Denies are out of scope for this module — the
implied deny-all-ingress rule already covers the default posture.

Only INGRESS is supported. EGRESS rules are rejected, because the module
exposes no `destination_ranges` and so cannot express one correctly.

The remaining validation rules exist because GCP reads *absent* as
*everything*:

- `source_ranges` must be non-empty, and every entry must be CIDR notation.
  GCP reads an INGRESS rule with no `sourceRanges` as `0.0.0.0/0`.
- `protocol` must not be `all`. `all` subsumes tcp, udp and sctp and cannot
  carry ports, so the ports rule below can never constrain it. Write one rule
  per protocol instead — the module renders one `allow` block per rule.
- `ports` must be non-empty for `tcp`, `udp` and `sctp`. GCP reads an
  `allowed[]` entry with no `ports` as every port of that protocol. Protocols
  that carry no ports — `icmp`, `esp`, `ah`, `ipip` — are exempt by necessity,
  since GCP rejects `ports` on them.
- `target_tags` must be non-empty when any source range is broader than `/8`.
  An untagged rule applies to every instance in the network, so a wide source
  plus no tags is "the internet to every VM".

The last two are written to close the *spelling* axis rather than enumerate
it. GCP documents `IPProtocol` as a well-known name **or** the protocol
number, so `tcp`, `" TCP "`, `6` and `006` are the same protocol; the rule
compares the number numerically after `trimspace`, so all four are caught
without listing them. Likewise, source width is measured by prefix length
rather than by matching any-source literals, which covers `0.0.0.0/0`, the
IPv6 `::/0` that Checkov does not recognise at all, and the
`0.0.0.0/1` + `128.0.0.0/1` split that evades any literal list.

The floor is *strictly* below `/8` rather than `/8`-or-wider, because
`10.0.0.0/8` is the canonical RFC1918 internal source and untagged internal
rules are a normal pattern that has to keep working.

Without these, the smallest rule the type system accepts —
`{ name = "x", protocol = "tcp" }` — plans as "allow the entire internet to
every TCP port on every VM", and **Checkov passes it clean**, because with
`source_ranges = []` there is no `0.0.0.0/0` literal for its checks to match.

### What still gets through

These validations are a floor, not proof of containment — HCL cannot express
CIDR arithmetic. Three shapes plan cleanly *and* draw zero findings from
Checkov, so nothing in the pipeline will stop them:

- **A wide public block at `/8` or narrower.** `1.0.0.0/8` is 16 million
  public addresses, but it is not broader than `/8`, so it is allowed
  untagged. The rule cannot tell a public `/8` from RFC1918's `10.0.0.0/8`
  without address-space arithmetic.
- **Several narrow blocks that add up.** `0.0.0.0/9` plus `0.128.0.0/9` plus
  `1.0.0.0/9` is checked one entry at a time, and no single entry is wide.
- **Almost any IPv6 source.** The `/8` floor is a single integer applied to
  both address families, so it is calibrated for IPv4 and is close to
  vacuous for IPv6: only `::/0` through `::/7` are caught. `2000::/8` is a
  thirty-second of global unicast — 2^120 addresses — and passes untagged,
  as does `2000::/16`. **Give IPv6 sources `target_tags` whatever their
  prefix length**; do not read the `::/0` coverage above as IPv6 being
  handled.

All three were verified against a real scan: the module plus any of these
shapes reports only the two known flow-log findings. Review the actual
address space your rules admit; the validations catch the careless cases,
not a determined one.

Do not treat a green scan as evidence that your rules are tight. Checkov's
ingress checks are syntactic matches against a hardcoded list of well-known
ports: `0.0.0.0/0` on tcp `22` is caught, but `0.0.0.0/0` on tcp `8000-8999`
produces no findings at all, identical to a clean module. `CKV2_GCP_12`
("unrestricted access to all ports") only fires on the literal all-ports
form and passes a rule open to the internet on `0-65535`. Review rule sources
yourself.

## Security scanning

`make security` runs Checkov against the committed `.checkov.baseline`. Two
findings are baselined, both `CKV_GCP_26` — VPC Flow Logs not enabled — one
per subnet in `examples/complete`.

This one is real, not a scanner artefact: substituting a static `log_config`
block clears it. It is accepted because the module deliberately exposes no
flow-log surface (see [Subnets](#subnets)). Enabling flow logs needs a change
request, not a caller-side setting.

### What suppression actually means

A Checkov baseline keys on the pair *(resource address, check ID)*. Once a
pair is suppressed it stays suppressed **whatever later causes it to fire** —
the baseline records that the pair was failing, not why. So a baselined check
is not "this specific known issue is accepted", it is "this check is off for
this resource". Treat adding one as switching a check off.

### The baseline is keyed to the example subnet names

Baseline records address subnets by name, so `.checkov.baseline` is coupled to
the names used in `examples/`. Renaming a subnet in *either* example breaks
`make security` with no change to the module at all — renaming
`examples/basic`'s subnet to `web` makes the scan exit 1 on
`CKV_GCP_26 FAILED for ...this["web"]`. **Rename an example subnet, regenerate
the baseline.**

Both examples currently name their subnet `app`, so they share the resource
address `module.network.google_compute_subnetwork.this["app"]`, with two
consequences. Suppressing a check for that address suppresses it for both
examples at once. And when the same (address, check) pair fails from both
calling files, Checkov collapses it to a single record attributed to just one
of them — here `examples/complete` — so `examples/basic`'s own flow-log
finding is currently both invisible in the report and suppressed by an entry
recorded from the other example.

That is why `CKV_GCP_74` (`private_ip_google_access`) is **not** baselined,
even though it did fail initially. Checkov resolves values through
`each.value` and `for_each` perfectly well; what it cannot resolve is a value
supplied *only* by an `optional(...)` type default. If no caller passes the
attribute, it reads as unset. The fix is therefore to pass the value
explicitly at the call site, which both examples now do — not to baseline it.
Suppressing it would have switched off a genuine check: with the attribute
baselined, setting `private_ip_google_access = false` on both subnets still
exited 0. It now correctly fails.

## Testing

```bash
terraform init -backend=false
terraform test
```

Tests use `mock_provider`, so they need no Google Cloud credentials.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | >= 6.0, < 7.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | 6.50.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_compute_firewall.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_network.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_router.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router) | resource |
| [google_compute_router_nat.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat) | resource |
| [google_compute_subnetwork.this](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_firewall_rules"></a> [firewall\_rules](#input\_firewall\_rules) | Firewall rules applied to the network. All are allow rules. | <pre>list(object({<br/>    name          = string<br/>    direction     = optional(string, "INGRESS")<br/>    priority      = optional(number, 1000)<br/>    source_ranges = optional(list(string), [])<br/>    target_tags   = optional(list(string), [])<br/>    protocol      = string<br/>    ports         = optional(list(string), [])<br/>  }))</pre> | `[]` | no |
| <a name="input_mtu"></a> [mtu](#input\_mtu) | MTU of the network in bytes. | `number` | `1460` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the VPC network. | `string` | n/a | yes |
| <a name="input_nat_enabled"></a> [nat\_enabled](#input\_nat\_enabled) | Whether a Cloud Router and Cloud NAT gateway are created. | `bool` | `false` | no |
| <a name="input_nat_region"></a> [nat\_region](#input\_nat\_region) | Region the Cloud Router and NAT gateway are created in. Required when nat\_enabled is true. | `string` | `null` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | ID of the project the network is created in. | `string` | n/a | yes |
| <a name="input_routing_mode"></a> [routing\_mode](#input\_routing\_mode) | REGIONAL keeps routes within a region; GLOBAL propagates them across regions. | `string` | `"REGIONAL"` | no |
| <a name="input_subnet_name_prefix"></a> [subnet\_name\_prefix](#input\_subnet\_name\_prefix) | Prefix prepended to every subnet's name. Subnetwork names are unique per project and region rather than per network, so this lets the same configuration be applied twice in one project without colliding. | `string` | `""` | no |
| <a name="input_subnets"></a> [subnets](#input\_subnets) | Subnets created in the network. | <pre>list(object({<br/>    name                     = string<br/>    ip_cidr_range            = string<br/>    region                   = string<br/>    private_ip_google_access = optional(bool, true)<br/>    secondary_ranges = optional(list(object({<br/>      range_name    = string<br/>      ip_cidr_range = string<br/>    })), [])<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_network_id"></a> [network\_id](#output\_network\_id) | Terraform identifier for the VPC network. |
| <a name="output_network_name"></a> [network\_name](#output\_network\_name) | Name of the VPC network. |
| <a name="output_network_self_link"></a> [network\_self\_link](#output\_network\_self\_link) | URI of the VPC network. |
| <a name="output_subnet_names"></a> [subnet\_names](#output\_subnet\_names) | Map of the subnet key supplied in var.subnets to the name actually created, which differs when subnet\_name\_prefix is set. |
| <a name="output_subnet_self_links"></a> [subnet\_self\_links](#output\_subnet\_self\_links) | Map of the subnet key supplied in var.subnets to the subnet's URI. The key is the supplied key, which differs from the created name when subnet\_name\_prefix is set. |
<!-- END_TF_DOCS -->

## Contributing

Raise a change request through the module registry, or open an issue on this
repository using the change request template.
