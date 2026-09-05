# Étage 2 — configuration applicative de Forgejo.
#
# Utilisateurs, organisations, dépôts, protections de branche, webhooks, et les
# secrets et variables Actions. C'est cet étage qui supprime définitivement le
# piège « Secrets vs Variables » : le type est écrit dans le code, il n'y a plus
# d'onglet où se tromper.
#
# Prérequis : Forgejo répond et un jeton d'administration existe.
terraform {
  required_version = ">= 1.6"
  required_providers {
    forgejo = { source = "svalabs/forgejo", version = "~> 1.6" }
    sops    = { source = "carlpett/sops", version = "~> 1.2" }
  }
}
