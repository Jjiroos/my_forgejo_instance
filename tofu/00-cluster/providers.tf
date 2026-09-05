data "sops_file" "secrets" {
  source_file = "${path.module}/../../secrets/piserv.sops.yaml"
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}
