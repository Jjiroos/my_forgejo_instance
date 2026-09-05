data "sops_file" "secrets" {
  source_file = "${path.module}/../../secrets/piserv.sops.yaml"
}

provider "forgejo" {
  host      = var.forgejo_url
  api_token = data.sops_file.secrets.data["forgejo.admin_api_token"]
}
