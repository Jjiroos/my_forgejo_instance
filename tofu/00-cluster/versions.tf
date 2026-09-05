# Étage 1 — ressources k3s.
#
# Ce que fait cet étage : namespaces, quotas, NetworkPolicies, StatefulSets du
# runner et de SonarQube. Autrement dit ce qui vit aujourd'hui dans k3s/, qui
# sera migré ici puis supprimé de sa place actuelle.
#
# Prérequis : le playbook Ansible a tourné, k3s répond, le kubeconfig existe.
terraform {
  required_version = ">= 1.6"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    sops       = { source = "carlpett/sops", version = "~> 1.2" }
  }
}
