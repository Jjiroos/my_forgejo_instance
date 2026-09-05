# Étage 3 — SonarQube, et le câblage entre les deux services.
#
# Il déclare à la fois le jeton d'analyse côté SonarQube et le secret Actions
# côté Forgejo qui le consomme. Les deux providers cohabitent volontairement
# dans cet étage : c'est ce qui permet au jeton de ne jamais transiter par un
# humain ni par un fichier intermédiaire.
#
# Prérequis : les étages 1 et 2 sont appliqués, SonarQube répond.
terraform {
  required_version = ">= 1.6"
  required_providers {
    sonarqube = { source = "jdamata/sonarqube", version = "~> 0.16" }
    forgejo   = { source = "svalabs/forgejo", version = "~> 1.6" }
    sops      = { source = "carlpett/sops", version = "~> 1.2" }
  }
}
