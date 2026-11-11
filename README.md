# SYS-350 Enrichment: Terraform CI/CD with Dockur VMs

Student: lsavage (Student A, host ports 3000-3012)

Every push to cicd-enterprise runs the enterprise-build Terraform config through
lint -> validate -> plan -> policy -> gated apply -> smoke tests.

## Stack

| Container        | Image             | Host ports                |
|------------------|-------------------|---------------------------|
| lsavage-gitea    | gitea/gitea       | 3000                      |
| lsavage-apache   | httpd             | 3001                      |
| lsavage-win11    | dockurr/windows   | RDP 3002, viewer 3003     |
| lsavage-win2025  | dockurr/windows   | RDP 3004, viewer 3005     |

## Pipeline

- `check` (GitHub-hosted): fmt, init, validate, plan, plan artifact, policy tests
- `services-test` (GitHub-hosted): applies gitea + apache as `ci-*`, smoke tests them, destroys them
- `deploy` (self-hosted runner, label `local`): waits for approval on the
  `enterprise-build` environment, then plans, applies and smoke tests the stack

## Files

- `main.tf`, `terraform.tfvars`: the dockur stack
- `service-images.yaml`, `policies/check.sh`: the image contract and policy checks
- `ci/github-services.tfvars`, `tests/smoke.sh`: the services lane and smoke tests
- `.github/workflows/cicd.yml`: the workflow
