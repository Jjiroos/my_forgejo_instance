# Forgejo self-hosted — home server (Raspberry Pi 5 / ARM64)

Déploiement reproductible d'une forge **Forgejo** auto-hébergée, accessible depuis
Internet en HTTPS *trusted*, sur un serveur maison. Testé sur Raspberry Pi 5
(Debian 12, ARM64) mais valable sur tout Debian 12+ / Ubuntu 22.04+ (ARM64 ou AMD64).

La procédure complète est dans **[SETUP.md](SETUP.md)**, et la CI auto-hébergée dans **[SETUP-K3S.md](SETUP-K3S.md)**.

## Ce que ça monte

| Brique | Rôle |
|---|---|
| **Forgejo 11** (Docker) | la forge : dépôts git, web UI, serveur Git LFS intégré |
| **PostgreSQL 16** (Docker) | base de données |
| **Nginx** | reverse proxy TLS sur le port `8181` + hardening (HSTS, `server_tokens off`, rate-limit login) |
| **acme.sh + DuckDNS** | certificat Let's Encrypt renouvelé automatiquement, validation DNS-01 (aucune CA à installer côté client) |
| **fail2ban** | jails `sshd` + `forgejo` contre le brute-force |
| **systemd** | `forgejo.service` — démarrage automatique au boot |
| **k3s** (mono-nœud) | cluster hébergeant les runners **Forgejo Actions** : CI maison, aucun runner cloud |

Une seule exposition publique : le port `8181/tcp` redirigé par la box.
SSH Forgejo désactivé, clones en HTTPS + access token.

```
Internet ──:8181──► box (port-forward) ──► serveur ──► nginx (TLS) ──► 127.0.0.1:3000 ──► Forgejo ──► PostgreSQL
                                                                                            ▲
                                              k3s ──► runner Actions ──► Docker-in-Docker ──┘
                                                      (client sortant, aucun port ouvert)
```

## Démarrage rapide

```bash
git clone <ce-dépôt> /opt/forgejo && cd /opt/forgejo
cp .env-template .env && chmod 600 .env   # renseigner domaine + mot de passe PostgreSQL
docker compose up -d
```

Cela ne couvre que les conteneurs. Le sous-domaine DuckDNS, le certificat, nginx,
fail2ban, le service systemd et le port-forward sont détaillés pas à pas dans
[SETUP.md](SETUP.md) — à faire dans l'ordre pour une instance réellement exposée.

## Contenu du dépôt

| Fichier | Description |
|---|---|
| `SETUP.md` | guide d'installation + runbook d'exploitation de la forge |
| `SETUP-K3S.md` | guide du cluster k3s et des runners Forgejo Actions |
| `docker-compose.yml` | services `forgejo` + `db`, paramétrés par `.env` |
| `k3s/` | manifestes du runner (namespace + quota, config act_runner, StatefulSet) et `apply.sh` |
| `.forgejo/workflows/ci-demo.yml` | workflow de démonstration, sert de test de recette |
| `.env-template` | gabarit de configuration à copier en `.env` |
| `.gitignore` | exclut `.env`, `data/`, `postgres-data/`, certificats, kubeconfig |

Les données runtime (`data/`, `postgres-data/`) et les secrets (`.env`, clés TLS)
ne sont **pas** versionnés : ce dépôt ne contient que la configuration.

## À venir

- **Analyse SonarQube** en CI : le runner k3s est prêt à l'accueillir, il reste à
  déployer un serveur SonarQube sur le LAN et à vérifier la disponibilité d'une
  image arm64 pour le scanner (voir la dernière section de [SETUP-K3S.md](SETUP-K3S.md)).
