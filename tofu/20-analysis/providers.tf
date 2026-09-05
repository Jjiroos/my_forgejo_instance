data "sops_file" "secrets" {
  source_file = "${path.module}/../../secrets/piserv.sops.yaml"
}

provider "sonarqube" {
  host = var.sonarqube_url
  user = "admin"
  pass = data.sops_file.secrets.data["sonarqube.admin_password"]
}

provider "forgejo" {
  host      = var.forgejo_url
  api_token = data.sops_file.secrets.data["forgejo.admin_api_token"]
}
