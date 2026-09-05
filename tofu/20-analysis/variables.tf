variable "sonarqube_url" {
  description = "URL de SonarQube vue depuis la machine qui exécute OpenTofu."
  type        = string
}

variable "forgejo_url" {
  description = "URL complète de la forge, port compris."
  type        = string
}
