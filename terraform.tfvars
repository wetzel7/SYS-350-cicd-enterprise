student_name = "lsavage"
networks     = ["devops", "internal", "web"]

# "Enterprise Build assignment" splits host ports by range: Student A uses 3000-3012,
# Student B uses 4000-4012. Keep every external port in your range.
services = {
  "gitea" = {
    image   = "gitea/gitea"
    network = "devops"
    ports   = [{ internal = 3000, external = 3000 }]
  }
  "apache" = {
    image   = "httpd"
    network = "web"
    ports   = [{ internal = 80, external = 3001 }]
  }
}

vms = {
  "lsavage-win11" = {
    os          = "win11"
    rdp_port    = 3002
    viewer_port = 3003
    memory_mb   = 2048
  }
  "lsavage-win2025" = {
    os          = "win2025"
    rdp_port    = 3004
    viewer_port = 3005
  }
}
