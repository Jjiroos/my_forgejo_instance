# Forgejo self-hosted — home server (Raspberry Pi 5 / ARM64)

Déploiement reproductible d'une forge **Forgejo** auto-hébergée, accessible depuis
Internet en HTTPS *trusted*, sur un serveur maison. Testé sur Raspberry Pi 5
(Debian 12, ARM64) mais valable sur tout Debian 12+ / Ubuntu 22.04+ (ARM64 ou AMD64).

La procédure complète est dans **[SETUP.md](SETUP.md)**.

## Ce que ça monte

| Brique | Rôle |
|---|---|
| **Forgejo 11** (Docker) | la forge : dépôts git, web UI, serveur Git LFS intégré |
| **PostgreSQL 16** (Docker) | base de données |
| **Nginx** | reverse proxy TLS sur le port `8181` + hardening (HSTS, `server_tokens off`, rate-limit login) |
| **acme.sh + DuckDNS** | certificat Let's Encrypt renouvelé automatiquement, validation DNS-01 (aucune CA à installer côté client) |
| **fail2ban** | jails `sshd` + `forgejo` contre le brute-force |
| **systemd** | `forgejo.service` — démarrage automatique au boot |

Une seule exposition publique : le port `8181/tcp` redirigé par la box.
SSH Forgejo désactivé, clones en HTTPS + access token.

```
Internet ──:8181──► box (port-forward) ──► Pi ──► nginx (TLS) ──► 127.0.0.1:3000 ──► Forgejo ──► PostgreSQL
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
| `SETUP.md` | guide d'installation + runbook d'exploitation (17 sections) |
| `docker-compose.yml` | services `forgejo` + `db`, paramétrés par `.env` |
| `.env-template` | gabarit de configuration à copier en `.env` |
| `.gitignore` | exclut `.env`, `data/`, `postgres-data/`, certificats |

Les données runtime (`data/`, `postgres-data/`) et les secrets (`.env`, clés TLS)
ne sont **pas** versionnés : ce dépôt ne contient que la configuration.

## À venir

- **Forgejo Actions** + cluster de runners **k3s** sur le même nœud (CI maison),
  premier job visé : analyse **SonarQube**. Pas encore implémenté — les manifestes
  arriveront ici une fois le runner en production.
