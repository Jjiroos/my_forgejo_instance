# Forgejo self-hosted — home server (Raspberry Pi 5 / ARM64)

Déploiement reproductible d'une forge **Forgejo** auto-hébergée, accessible depuis
Internet en HTTPS *trusted*, sur un serveur maison. Testé sur Raspberry Pi 5
(Debian 12, ARM64) mais valable sur tout Debian 12+ / Ubuntu 22.04+ (ARM64 ou AMD64).

La procédure complète est dans **[SETUP.md](SETUP.md)**, la CI auto-hébergée dans **[SETUP-K3S.md](SETUP-K3S.md)**, et l'analyse de code dans **[SETUP-SONARQUBE.md](SETUP-SONARQUBE.md)**. L'automatisation de l'ensemble est décrite dans **[IAC.md](IAC.md)**.

Le code d'infrastructure n'est pas seulement publié, il est **éprouvé** : à chaque commit, un runner GitHub jetable — amd64 et arm64 — reçoit le playbook, deux fois de suite, et le job échoue si le second passage modifie quoi que ce soit. Détail en [IAC.md §9](IAC.md#9-éprouver-le-code--la-ci-github).

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
| **SonarQube** Community | analyse de qualité et de sécurité du code, déclenchée par la CI |

Une seule exposition publique : le port `8181/tcp` redirigé par la box.
SSH Forgejo désactivé, clones en HTTPS + access token.

```
Internet ──:8181──► box (port-forward) ──► serveur ──► nginx (TLS) ──► 127.0.0.1:3000 ──► Forgejo ──► PostgreSQL
                                                          │                                 ▲
    poste admin (LAN) ──:9443── TLS ──────────────────────┤                                 │
                                                          │                                 │
                    ┌───────── k3s (mono-nœud) ───────────┼───────────────────────────┐     │
                    │  runner Actions ──► Docker-in-Docker ──► conteneurs de job ──────┼─────┘
                    │                                     │        │                  │
                    │  SonarQube ◄────────────────────────┘────────┘                  │
                    └─────────────────────────────────────────────────────────────────┘
        Seul le 8181 est exposé publiquement. Le 9443 est réservé au poste
        d'administration ; le reste ne sort jamais du réseau local.
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

## Brancher l'analyse SonarQube sur un dépôt

SonarQube est en veille par défaut : le job CI le réveille, il se rendort après
30 min sans analyse. Un dépôt analysé a besoin de trois choses.

**1. Des secrets Forgejo**, de préférence au niveau utilisateur
(`/user/settings/actions/secrets`) pour servir à tous les dépôts. Ce sont des
*Secrets*, pas des *Variables*.

| Secret | Valeur |
|---|---|
| `SONAR_HOST_URL` | `http://<IP_LAN>:9000` |
| `SONAR_TOKEN` | jeton d'analyse SonarQube ([§4](SETUP-SONARQUBE.md#4-première-connexion-et-token-ci)) |
| `SONAR_KUBE_TOKEN` | `kubectl -n sonarqube get secret sonar-waker-token -o jsonpath='{.data.token}' \| base64 -d` |
| `SONAR_KUBE_CA` | `kubectl -n sonarqube get secret sonar-waker-token -o jsonpath='{.data.ca\.crt}' \| base64 -d` — bloc PEM entier |

**2. Des fichiers copiés depuis `examples/`**

| Fichier | Destination dans le dépôt analysé |
|---|---|
| `sonar/sonar-wake.sh` | racine |
| `workflows/sonar-analysis.yml` (ou `sonar-cpp.yml` + `sonar/cppcheck-to-sonar.py` pour du C/C++) | `.forgejo/workflows/` |
| `workflows/sonar-wake.yml` — bouton « Allumer SonarQube » pour consulter les rapports | `.forgejo/workflows/` d'un seul dépôt suffit |

**3. Côté cluster, une fois** (recommandé) : un jeton utilisateur d'un
administrateur SonarQube, pour que la veille n'éteigne jamais le serveur pendant
le traitement d'un rapport.

```bash
kubectl -n sonarqube create secret generic sonarqube-idle-token --from-literal=token='<JETON>'
```

Détail et raisons : [SETUP-SONARQUBE.md §5](SETUP-SONARQUBE.md#5-brancher-un-dépôt)
et [§8](SETUP-SONARQUBE.md#mise-en-veille).

## Contenu du dépôt

| Fichier | Description |
|---|---|
| `SETUP.md` | guide d'installation + runbook d'exploitation de la forge |
| `SETUP-K3S.md` | guide du cluster k3s et des runners Forgejo Actions |
| `SETUP-SONARQUBE.md` | guide du serveur SonarQube et de l'analyse en CI |
| `IAC.md` | industrialisation Ansible + OpenTofu : frontière, étages, secrets |
| `ansible/` | préparation de l'hôte — paquets, pare-feu, certificats, nginx, Docker, pile Forgejo, cluster k3s |
| `tofu/` | configuration par API — cluster, Forgejo, SonarQube |
| `secrets/` | **gabarits seuls, sans aucune valeur.** Les fichiers chiffrés restent hors du dépôt — cf. [IAC.md §6](IAC.md#6-secrets--hors-du-dépôt-sans-exception) |
| `docker-compose.yml` | services `forgejo` + `db`, paramétrés par `.env` |
| `k3s/` | manifestes par composant — `runner/`, `sonarqube/` — et `apply.sh` |
| `examples/` | workflows d'analyse prêts à copier, script de réveil de SonarQube, convertisseur cppcheck → SonarQube |
| `.forgejo/workflows/ci-demo.yml` | workflow de démonstration, sert de test de recette |
| `.github/workflows/` | CI publique : lint de l'IaC, garde anti-secret, convergence réelle sur runner jetable |
| `.env-template` | gabarit de configuration à copier en `.env` |
| `.gitignore` | exclut `.env`, `data/`, `postgres-data/`, certificats, kubeconfig |

Les données runtime (`data/`, `postgres-data/`) et les secrets (`.env`, clés TLS)
ne sont **pas** versionnés : ce dépôt ne contient que la configuration.

## Bon à savoir

Tout tient sur une seule machine à 8 Gio. Le budget mémoire est donc le vrai
facteur limitant, pas le CPU : chaque brique est bornée par un `ResourceQuota`
k3s pour qu'aucune ne puisse faire tomber les autres. Les chiffres mesurés et
les combinaisons qui ne rentrent pas sont dans
[SETUP-SONARQUBE.md §8](SETUP-SONARQUBE.md#8-budget-mémoire).
