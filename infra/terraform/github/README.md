# GitHub main protection

Declares `main`'s branch protection on DeckDumpster/ephemeral-ci: the checks it
requires today plus `infra`. The existing protection is imported (`import.tf`),
never recreated.

Applied by the Concierge with a GitHub token (repository administration).

```sh
cd infra/terraform/github
export GITHUB_TOKEN=...
gh api repos/DeckDumpster/ephemeral-ci/branches/main/protection   # read today's values
terraform init -backend-config="bucket=<StateBucketName>" \
  -backend-config='assume_role={role_arn="<terraform-deploy role ARN>"}'   # state is 403 without the role
terraform plan  -var-file=main.tfvars   # must be: 1 to import, 0 to add, 1 to change, 0 to destroy; the change adds `infra` to contexts
terraform apply -var-file=main.tfvars
```

`main.tfvars` is written from the `gh api` output and not committed:

```hcl
existing_required_checks        = ["test"]   # required_status_checks.contexts, as read
enforce_admins                  = true       # enforce_admins.enabled (true on main today)
strict_status_checks            = false      # required_status_checks.strict
required_approving_review_count = null       # required_pull_request_reviews.required_approving_review_count, or null
```

If the plan shows any change other than the added `infra` context, a variable
does not match live protection or the protection has an attribute this root
does not model: stop and fix the declaration before applying.

Offline checks (what CI's `infra` job runs):
`terraform init -backend=false && terraform validate && terraform test`.
