# Adopt main's existing protection; never recreate it. Once the state holds it
# this file has done its work and may be deleted.
import {
  for_each = var.import_enabled ? toset(["main"]) : toset([])
  to       = github_branch_protection.main
  id       = "ephemeral-ci:main"
}
