mock_provider "github" {}

variables {
  existing_required_checks = ["test"]
  enforce_admins           = false
  strict_status_checks     = false
  import_enabled           = false
}

run "infra_is_added_to_existing_checks" {
  command = plan

  assert {
    condition     = toset(github_branch_protection.main.required_status_checks[0].contexts) == toset(["test", "infra"])
    error_message = "main must require the existing checks plus infra"
  }
}

run "existing_checks_are_never_dropped" {
  command = plan

  variables {
    existing_required_checks = ["test", "base-check", "infra"]
  }

  assert {
    condition     = length(github_branch_protection.main.required_status_checks[0].contexts) == 3
    error_message = "every existing check is kept and infra is not duplicated"
  }
}

run "empty_existing_list_is_refused" {
  command = plan

  variables {
    existing_required_checks = []
  }

  expect_failures = [var.existing_required_checks]
}

run "repository_id_is_the_node_id_not_the_name" {
  command = plan

  override_data {
    target = data.github_repository.this
    values = {
      node_id = "R_kgDOUcRKZg"
    }
  }

  assert {
    condition     = github_branch_protection.main.repository_id == "R_kgDOUcRKZg"
    error_message = "repository_id must be the node id the provider stores; the name forces replacement of the import"
  }

  assert {
    condition     = length(github_branch_protection.main.force_push_bypassers) == 0
    error_message = "force_push_bypassers must be [] to match the imported value"
  }
}
