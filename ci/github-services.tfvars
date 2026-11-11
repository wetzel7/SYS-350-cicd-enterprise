# ci/github-services.tfvars: the gitea + apache test lane that runs on
# GitHub-hosted runners. vms = {} so no dockur containers are planned:
# GitHub runners have Docker but no /dev/kvm, so Windows VMs cannot run there.
student_name = "ci"
networks     = ["devops", "web"]
vms          = {}

services = {
  "gitea" = {
    image   = "gitea/gitea"
    network = "devops"
    ports   = [{ internal = 3000, external = 3000 }]
  }
  "apache" = {
    image   = "httpd"
    network = "web"
    ports   = [{ internal = 80, external = 80 }]
  }
}
