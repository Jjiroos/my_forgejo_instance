variable "kubeconfig_path" {
  description = "Chemin du kubeconfig k3s. Sur le nœud : /etc/rancher/k3s/k3s.yaml (root)."
  type        = string
  default     = "~/.kube/config"
}

variable "node_lan_ip" {
  description = "IP LAN du nœud. Utilisée par les hostPort et les hostAliases : les conteneurs joignent la forge sans repasser par l'IP publique."
  type        = string
}

variable "admin_workstation_ip" {
  description = "Poste autorisé à joindre l'IHM SonarQube. Voir SETUP-SONARQUBE.md §7 — c'est la NetworkPolicy qui filtre, pas UFW."
  type        = string
}

variable "forgejo_domain" {
  description = "Nom d'hôte public de la forge, sans le port."
  type        = string
}
