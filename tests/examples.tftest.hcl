mock_provider "google" {}

run "examples_basic_plans_cleanly" {
  command = plan

  module {
    source = "./examples/basic"
  }

  # The nightly tier-3 check requires every output to carry the run suffix, so
  # the subnet has to appear in this example's outputs or the one resource that
  # actually collides between runs goes unverified at runtime. Deleting the
  # output would narrow that check silently, since it only inspects whatever
  # outputs happen to exist.
  #
  # Asserting on the key also pins it to the unprefixed name, which is the
  # invariant Checkov depends on: a prefixed for_each key collapses the
  # resource address and loses the CKV_GCP_26 baseline entry.
  assert {
    condition     = output.subnet_names == { app = "app" }
    error_message = "with no suffix the subnet must be named exactly \"app\", got ${jsonencode(output.subnet_names)}"
  }

  assert {
    condition     = output.network_name == "serviceops-example-basic"
    error_message = "with no suffix the network name must be unchanged, got ${output.network_name}"
  }
}

# The non-empty branch of both ternaries in examples/basic. This is the path the
# nightly actually depends on and nothing else in the repo exercises it: the run
# above only ever evaluates the empty branch, and the module-level tests in
# features.tftest.hcl set subnet_name_prefix directly, bypassing the wiring that
# derives it from name_suffix.
run "examples_basic_applies_the_name_suffix" {
  command = plan

  module {
    source = "./examples/basic"
  }

  variables {
    name_suffix = "ci123"
  }

  # The network takes the suffix appended.
  assert {
    condition     = output.network_name == "serviceops-example-basic-ci123"
    error_message = "expected the suffix appended to the network name, got ${output.network_name}"
  }

  # The subnet takes it prepended, via subnet_name_prefix. The asymmetry is
  # deliberate — a subnet name is bounded and a prefix keeps the distinguishing
  # part first — and it is why the nightly matches the suffix bare rather than
  # as "-$SUFFIX".
  #
  # The map key stays unprefixed while the value changes, which is the whole
  # point of prefixing in the module: Checkov can only resolve a for_each key
  # that is a string literal.
  assert {
    condition     = output.subnet_names == { app = "ci123-app" }
    error_message = "expected the suffix prepended to the subnet name with the key left alone, got ${jsonencode(output.subnet_names)}"
  }
}

run "examples_complete_plans_cleanly" {
  command = plan

  module {
    source = "./examples/complete"
  }
}
