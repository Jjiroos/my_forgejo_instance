# Déploiement Forgejo sur Raspberry Pi (Debian / ARM64)

Guide de bout en bout pour instancier un serveur Forgejo **accessible publiquement** via DuckDNS + Let's Encrypt, avec PostgreSQL, Docker Compose, Nginx durci et fail2ban. Conçu pour un Raspberry Pi 5 mais valable sur tout serveur Debian 12+ / Ubuntu 22.04+ en ARM64 ou AMD64.

À la fin de cette procédure, des clients depuis Internet ouvrent `https://<SOUS_DOMAINE>.duckdns.org:8181/` sans avertissement SSL et sans installation manuelle de CA.

## Sommaire

1. [Prérequis](#1-prérequis)
2. [DuckDNS — sous-domaine public](#2-duckdns--sous-domaine-public)
3. [Dossier de travail et `.env`](#3-dossier-de-travail-et-env)
4. [`docker-compose.yml`](#4-docker-composeyml)
5. [Certificat Let's Encrypt (acme.sh + DNS-01)](#5-certificat-lets-encrypt-acmesh--dns-01)
6. [Nginx — reverse proxy + hardening](#6-nginx--reverse-proxy--hardening)
7. [fail2ban — anti brute-force](#7-fail2ban--anti-brute-force)
8. [Service systemd](#8-service-systemd)
9. [Box / routeur — redirection du port 8181](#9-box--routeur--redirection-du-port-8181)
10. [Premier démarrage et configuration Forgejo](#10-premier-démarrage-et-configuration-forgejo)
11. [Cloner et pousser un dépôt](#11-cloner-et-pousser-un-dépôt)
12. [Git LFS — gros fichiers binaires](#12-git-lfs--gros-fichiers-binaires)
13. [Exploitation au quotidien](#13-exploitation-au-quotidien)
14. [Bannissements fail2ban — consulter et lever](#14-bannissements-fail2ban--consulter-et-lever)
15. [Mises à jour](#15-mises-à-jour)
16. [Dépannage](#16-dépannage)
17. [Structure des fichiers](#17-structure-des-fichiers)

---

## 1. Prérequis

- Debian 12+ ou Ubuntu 22.04+ (ARM64 ou AMD64)
- Docker + Docker Compose (`docker --version`, `docker compose version`)
- Nginx (`nginx -v`)
- `sudo` disponible
- Un compte **DuckDNS** + un sous-domaine dédié (création : §2)
- Sur la box : capacité à faire du port-forwarding (§9)

Le port **8181** sera ouvert à la fois en local (UFW) et publiquement (box). Aucun autre port n'est forwardé sur Internet.

---

## 2. DuckDNS — sous-domaine public

DuckDNS fournit un sous-domaine `*.duckdns.org` qui suit ton IP publique. Il sert à la fois pour l'URL utilisateur et pour la validation DNS-01 du certificat.

### 2.1 Créer le sous-domaine

Sur https://www.duckdns.org/ :
1. Se connecter (GitHub, Google…)
2. Ajouter un sous-domaine (ex. `mon-forge`) → il pointe automatiquement vers ton IP publique
3. Noter le **token** affiché en haut de la page (identique pour tous les sous-domaines du compte)

### 2.2 Script de rafraîchissement automatique

Le script ci-dessous met à jour l'IP DuckDNS toutes les 5 min, ce qui couvre les changements d'IP publique chez ton FAI. Plusieurs sous-domaines peuvent être rafraîchis en un seul appel via la liste `domains=<sub1>,<sub2>` :

```bash
mkdir -p ~/duckdns
cat > ~/duckdns/update.sh <<'EOF'
#!/bin/bash
echo url="https://www.duckdns.org/update?domains=<SOUS_DOMAINE>&token=<TOKEN>&ip=" \
  | curl -k -o ~/duckdns/duck.log -K -
EOF
chmod 700 ~/duckdns/update.sh
~/duckdns/update.sh && cat ~/duckdns/duck.log   # doit afficher: OK
```

Programmer le cron :

```bash
( crontab -l 2>/dev/null; echo '*/5 * * * * ~/duckdns/update.sh >/dev/null 2>&1' ) | crontab -
```

---

## 3. Dossier de travail et `.env`

```bash
sudo mkdir -p /opt/forgejo
sudo chown -R $USER:$USER /opt/forgejo
cd /opt/forgejo
```

Générer un mot de passe PostgreSQL solide :

```bash
openssl rand -base64 32
```

Créer `/opt/forgejo/.env` à partir du gabarit versionné :

```bash
cp .env-template .env
chmod 600 .env
```

```env
# Sous-domaine public DuckDNS (§2) — sans le port
FORGEJO_DOMAIN=<SOUS_DOMAINE>.duckdns.org

POSTGRES_DB=forgejo
POSTGRES_USER=forgejo
POSTGRES_PASSWORD=<MOT_DE_PASSE_GENERE>
```

> `.env` est dans le `.gitignore` : il contient le mot de passe PostgreSQL et ne doit
> jamais partir sur un dépôt distant. Seul `.env-template` est versionné.

---

## 4. `docker-compose.yml`

```yaml
services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:11
    container_name: forgejo
    restart: unless-stopped
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - TZ=Europe/Paris
      - FORGEJO__database__DB_TYPE=postgres
      - FORGEJO__database__HOST=db:5432
      - FORGEJO__database__NAME=${POSTGRES_DB}
      - FORGEJO__database__USER=${POSTGRES_USER}
      - FORGEJO__database__PASSWD=${POSTGRES_PASSWORD}
      - FORGEJO__server__ROOT_URL=https://${FORGEJO_DOMAIN}:8181/
      - FORGEJO__server__HTTP_PORT=3000
      - FORGEJO__server__START_SSH_SERVER=false
      - FORGEJO__server__DISABLE_SSH=true
      - FORGEJO__log__MODE=console,file
      - FORGEJO__log__LEVEL=info
      # ── Forgejo Actions (runners k3s — voir SETUP-K3S.md) ──
      - FORGEJO__actions__ENABLED=true
      - FORGEJO__actions__DEFAULT_ACTIONS_URL=https://code.forgejo.org
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - forgejo-net

  db:
    image: postgres:16-alpine
    container_name: forgejo-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - forgejo-net

networks:
  forgejo-net:
```

Notes :

- `${FORGEJO_DOMAIN}` est lu depuis `.env` (§3) : le `docker-compose.yml` reste générique et publiable tel quel.
- `TZ=Europe/Paris` : aligne l'heure des logs Forgejo avec l'horloge système. **Indispensable** pour que fail2ban (qui compare les timestamps des logs à `findtime`) n'ignore pas les attaques par décalage UTC/CEST.
- `DISABLE_SSH=true` + `START_SSH_SERVER=false` : on n'expose pas SSH Forgejo, les clones se font en HTTPS (§11).
- `127.0.0.1:3000:3000` : Forgejo n'est jamais joignable en direct — uniquement via nginx.
- `MODE=console,file` : Forgejo écrit dans `gitea.log` (lu par fail2ban) **et** dans la sortie Docker (`docker logs`).
- `FORGEJO__actions__*` : active le moteur CI intégré. `DEFAULT_ACTIONS_URL=https://code.forgejo.org` fait résoudre les `uses: actions/checkout@v4` sur le miroir Forgejo ; les actions tierces se référencent par URL complète. Sans runner enregistré les workflows restent en attente — voir **[SETUP-K3S.md](SETUP-K3S.md)**.

---

## 5. Certificat Let's Encrypt (acme.sh + DNS-01)

Approche : certificat publiquement *trusted*, validé par un TXT record posé sur le sous-domaine DuckDNS. **Aucune CA à installer côté client.**

### 5.1 Installer acme.sh (en root)

```bash
curl -fsSL https://get.acme.sh | sudo sh -s email=<TON_EMAIL>
sudo /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
```

Un cron quotidien est créé automatiquement (renouvellement à T-30 jours, géré par acme.sh).

### 5.2 Émettre le certificat

```bash
sudo DuckDNS_Token=<TOKEN_DUCKDNS> \
  /root/.acme.sh/acme.sh --issue --dns dns_duckdns \
  -d <SOUS_DOMAINE>.duckdns.org
```

> ⚠️ Le nom de la variable est **`DuckDNS_Token`** (CamelCase). `DUCKDNS_TOKEN` est ignoré silencieusement.

Le token est mémorisé dans `/root/.acme.sh/account.conf` — inutile de le repasser au renouvellement.

### 5.3 Installer le certificat dans nginx

```bash
sudo mkdir -p /etc/nginx/ssl
sudo /root/.acme.sh/acme.sh --install-cert -d <SOUS_DOMAINE>.duckdns.org \
  --key-file       /etc/nginx/ssl/forgejo.key \
  --fullchain-file /etc/nginx/ssl/forgejo.crt \
  --reloadcmd      "systemctl reload nginx"
```

À chaque renouvellement, acme.sh remplace les fichiers et reload nginx automatiquement.

### 5.4 Forcer un renouvellement (test)

```bash
sudo /root/.acme.sh/acme.sh --renew -d <SOUS_DOMAINE>.duckdns.org --force
```

---

## 6. Nginx — reverse proxy + hardening

### 6.1 Masquer la version nginx (global)

Dans `/etc/nginx/nginx.conf`, sous `http { ... }`, décommenter / régler :

```nginx
server_tokens off;
```

### 6.2 Zone de rate-limit (global)

```bash
sudo tee /etc/nginx/conf.d/00-rate-limit.conf >/dev/null <<'EOF'
# Rate-limit zones (http context). Used by individual site configs.
limit_req_zone $binary_remote_addr zone=forgejo_login:10m rate=5r/m;
EOF
```

### 6.3 Site Forgejo

`/etc/nginx/sites-available/forgejo` :

```nginx
server {
    listen 8181 ssl http2;
    server_name <SOUS_DOMAINE>.duckdns.org;

    ssl_certificate     /etc/nginx/ssl/forgejo.crt;
    ssl_certificate_key /etc/nginx/ssl/forgejo.key;
    # Géré par acme.sh — voir §5
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    access_log /var/log/nginx/forgejo-access.log;
    error_log  /var/log/nginx/forgejo-error.log;

    client_max_body_size 500m;

    proxy_read_timeout      600s;
    proxy_send_timeout      600s;
    proxy_request_buffering off;

    # Common proxy headers (inherited by all locations)
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Anti brute-force : rate-limit sur la page de login (zone : §6.2)
    location = /user/login {
        limit_req zone=forgejo_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:3000;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}
```

### 6.4 Activer et appliquer

```bash
sudo ln -s /etc/nginx/sites-available/forgejo /etc/nginx/sites-enabled/forgejo
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

### 6.5 UFW

```bash
sudo ufw allow 8181/tcp
```

Ne **pas** ouvrir d'autres ports liés à Forgejo (le 2222 n'est plus utilisé, SSH Forgejo est désactivé).

---

## 7. fail2ban — anti brute-force

```bash
sudo apt-get install -y fail2ban
```

### 7.1 Filtre Forgejo

`/etc/fail2ban/filter.d/forgejo.conf` :

```ini
# Fail2Ban filter for Forgejo failed-auth attempts.
# Real client IP comes from X-Forwarded-For — nginx est dans la liste des
# proxys de confiance par défaut de Forgejo (127.0.0.0/8).
[Definition]
failregex = ^.*(Failed authentication attempt|invalid credentials|Attempted access of unknown user).*from <ADDR>.*$
            ^.*authentication.+failed.+from <ADDR>.*$
ignoreregex =
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
```

### 7.2 Jails

`/etc/fail2ban/jail.d/local.conf` :

```ini
# Debian 12 n'a pas /var/log/auth.log par défaut (systemd-journald only),
# donc la jail sshd doit utiliser le backend systemd.

[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16 10.0.0.0/8

[sshd]
enabled  = true
backend  = systemd

[forgejo]
enabled  = true
port     = 8181
filter   = forgejo
logpath  = /opt/forgejo/data/gitea/log/gitea.log
maxretry = 5
findtime = 10m
bantime  = 10m
```

> Le fichier de log `gitea.log` est créé par Forgejo grâce à `FORGEJO__log__MODE=console,file` (§4).

### 7.3 Activer

```bash
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban
sudo fail2ban-client status            # doit lister: forgejo, sshd
sudo fail2ban-client status sshd       # détail de la jail
sudo fail2ban-client status forgejo
```

### 7.4 Vérifier le filtre

```bash
sudo fail2ban-regex /opt/forgejo/data/gitea/log/gitea.log /etc/fail2ban/filter.d/forgejo.conf
```

→ doit afficher au moins `1 matched` après une tentative ratée.

---

## 8. Service systemd

`/etc/systemd/system/forgejo.service` :

```ini
[Unit]
Description=Forgejo
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/forgejo
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now forgejo
```

---

## 9. Box / routeur — redirection du port 8181

Sans ce port-forward, Forgejo reste joignable depuis le LAN uniquement.

### Interface de la box du fournisseur d'accès internet

Les libellés varient d'un fournisseur d'accès internet à l'autre, la logique est identique partout.

1. http://192.168.1.1/ → connexion admin
2. **Réseau** → **NAT/PAT** (ou « Redirections de ports »)
3. Ajouter une règle :

   | Champ              | Valeur                  |
   |--------------------|-------------------------|
   | Nom / Application  | `Forgejo HTTPS`         |
   | Protocole          | **TCP**                 |
   | Port externe       | **8181**                |
   | Port interne       | **8181**                |
   | Équipement cible   | IP LAN du serveur (ex. `192.168.1.50`) |

4. **Activer** + **Enregistrer**
5. Dans **Réseau > DHCP**, créer une **réservation statique** pour le MAC du Pi → garantit que son IP LAN ne change pas

### À NE PAS forwarder

22 (SSH du serveur), 5432 (PostgreSQL), et plus généralement **tout autre service écoutant sur le LAN** (bases de données, monitoring, serveurs de jeu…). Le forward unique du 8181 doit rester la *seule* exposition publique.

---

## 10. Premier démarrage et configuration Forgejo

### 10.1 Démarrer

```bash
docker compose -f /opt/forgejo/docker-compose.yml ps
docker compose -f /opt/forgejo/docker-compose.yml logs -f forgejo
```

Puis ouvrir `https://<SOUS_DOMAINE>.duckdns.org:8181/`. Le certif Let's Encrypt est *trusted* nativement — aucun avertissement SSL.

### 10.2 Page d'installation

- La base PostgreSQL est pré-renseignée par les env vars (§4)
- Créer le **compte administrateur**
- Valider

### 10.3 Verrouillage post-install

Une fois loggué admin :

- **Activer 2FA** : `Paramètres > Sécurité > Two-Factor Authentication`
- Le drapeau `DISABLE_REGISTRATION = true` doit déjà être actif dans `app.ini` — vérifier :

  ```bash
  sudo grep -E '^(INSTALL_LOCK|DISABLE_REGISTRATION)' /opt/forgejo/data/gitea/conf/app.ini
  ```

### 10.4 Audit `SECRET_KEY`

L'installeur Forgejo peut laisser `SECRET_KEY` vide dans `app.ini`. Cette clé signe les cookies de session et les CSRF tokens — elle doit être peuplée.

```bash
sudo awk -F'=' '/^SECRET_KEY/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print "SECRET_KEY length:", length($2)}' \
  /opt/forgejo/data/gitea/conf/app.ini
```

Si la longueur est `0`, regénérer (déconnecte les sessions actives ; pas de perte de données) :

```bash
NEW_KEY=$(docker exec forgejo forgejo generate secret SECRET_KEY)
docker compose -f /opt/forgejo/docker-compose.yml down
sudo sed -i "s|^SECRET_KEY =.*|SECRET_KEY = ${NEW_KEY}|" /opt/forgejo/data/gitea/conf/app.ini
docker compose -f /opt/forgejo/docker-compose.yml up -d
```

### 10.5 Gérer les utilisateurs (CLI admin)

L'inscription publique est **désactivée** (`DISABLE_REGISTRATION = true`, §10.3) : la page de login s'affiche mais le bouton « Register » est masqué. C'est volontaire — sur un serveur exposé à Internet, personne ne doit pouvoir se créer un compte tout seul. **C'est donc l'admin qui crée les comptes**, via la CLI Forgejo embarquée dans le conteneur.

> ⚠️ Toujours préfixer par **`-u git`**. Sans ça la commande tourne en root et crée des fichiers que Forgejo ne peut plus lire → permissions cassées.

#### Créer un utilisateur

```bash
docker exec -u git forgejo forgejo admin user create \
  --username <PSEUDO> \
  --email <PSEUDO>@example.com \
  --password '<MDP_TEMPORAIRE>' \
  --must-change-password
```

| Option                   | Effet                                                                 |
|--------------------------|-----------------------------------------------------------------------|
| `--must-change-password` | Force le choix d'un nouveau mot de passe à la 1ʳᵉ connexion (recommandé) |
| `--random-password`      | Forgejo génère le mot de passe et l'affiche (remplace `--password`)    |
| `--admin`                | Donne les droits admin — **à éviter** pour de simples utilisateurs    |

> 📭 Le mailer est désactivé (`[mailer] ENABLED = false`, §4) : Forgejo **n'envoie aucun email**. L'email demandé n'est qu'un placeholder (l'utilisateur le corrigera dans *Settings → Account*), et c'est à toi de transmettre `login` + mot de passe temporaire de la main à la main (Signal, etc.).

#### Lister les utilisateurs

```bash
docker exec -u git forgejo forgejo admin user list
```

#### Autres opérations courantes

```bash
# Réinitialiser un mot de passe oublié
docker exec -u git forgejo forgejo admin user change-password \
  --username <PSEUDO> --password '<NOUVEAU_MDP>' --must-change-password

# Forcer le changement de mot de passe à la prochaine connexion
docker exec -u git forgejo forgejo admin user must-change-password <PSEUDO>

# Promouvoir / rétrograder un admin : se fait dans l'interface web
#   Site Administration → Utilisateurs → <user> → Administrateur

# Supprimer un utilisateur (--purge efface aussi ses dépôts/commentaires)
docker exec -u git forgejo forgejo admin user delete --username <PSEUDO> --purge

# Aide complète sur les sous-commandes
docker exec -u git forgejo forgejo admin user --help
```

> La création/suppression est **immédiate** : pas besoin de redémarrer le conteneur.

---

## 11. Cloner et pousser un dépôt

Le SSH Forgejo étant désactivé, on clone en HTTPS authentifié par un **access token** (Forgejo > `Paramètres > Applications > Générer un nouveau token`).

```bash
git clone https://<SOUS_DOMAINE>.duckdns.org:8181/<utilisateur>/<depot>.git
```

Pour push :

```bash
git config --global credential.helper store
# au premier push : login = <utilisateur Forgejo>, password = <ACCESS_TOKEN>
```

---

## 12. Git LFS — gros fichiers binaires

Git LFS (Large File Storage) stocke les fichiers binaires lourds (assets de jeu, vidéos, archives…) hors de l'historique git classique : git ne versionne qu'un pointeur texte, et le binaire part vers le serveur LFS. **Forgejo embarque un serveur LFS natif** — pas besoin d'un second service. Les objets sont stockés sur le même volume Docker que le reste des données Forgejo.

```
Client git                Forgejo (conteneur)            Hôte (Pi)
──────────                ───────────────────            ─────────────────────
git push      ─────────►  API git  → dépôt git           ./data/gitea/...
git lfs push  ─────────►  API LFS  → /data/git/lfs/    →  ./data/git/lfs/
```

### 12.1 Activer le serveur LFS (docker-compose.yml)

Contrairement à une install native (édition de `app.ini`), tout passe par les variables d'environnement du service `forgejo` (§4). Ajouter dans le bloc `environment:` :

```yaml
      # ── Git LFS ──
      - FORGEJO__server__LFS_START_SERVER=true
      - FORGEJO__lfs__STORAGE_TYPE=local
      - FORGEJO__lfs__PATH=/data/git/lfs
```

Notes :

- `LFS_START_SERVER=true` active l'endpoint LFS intégré, exposé sur le même port que le git HTTPS (rien de plus à ouvrir).
- `FORGEJO__lfs__PATH=/data/git/lfs` : chemin **dans le conteneur**, le défaut de l'image Docker — l'expliciter évite qu'un changement de version le déplace. Comme `./data` est monté sur `/data` (§4), les objets atterrissent sur l'hôte dans `/opt/forgejo/data/git/lfs/` et survivent aux redémarrages / upgrades. **Une restauration doit remettre les objets à ce même chemin**, sinon les dépôts pointent vers des fichiers introuvables.
- **Pas de `mkdir`/`chown` manuel** : Forgejo crée le dossier au démarrage avec l'UID du conteneur (`USER_UID=1000`).
- **Sur piserv**, ces réglages ont été posés à la main dans `data/gitea/conf/app.ini` (`[server] LFS_START_SERVER`, `LFS_HTTP_AUTH_EXPIRY = 20m`, `LFS_MAX_FILE_SIZE = 0`, `LFS_LOCKS_PAGING_NUM = 50` ; `[lfs] PATH = /data/git/lfs`), pas dans `docker-compose.yml`. L'effet est le même ; au démarrage, les variables `FORGEJO__*` sont réécrites dans `app.ini` et l'emportent.
- **Secret JWT** : inutile de le générer à la main. Au premier démarrage avec LFS activé, Forgejo génère `LFS_JWT_SECRET` et le persiste dans `data/gitea/conf/app.ini`. Pour le vérifier : `sudo grep LFS_JWT_SECRET /opt/forgejo/data/gitea/conf/app.ini`.

### 12.2 Appliquer

```bash
cd /opt/forgejo
docker compose up -d            # recrée le conteneur avec la nouvelle config
# ou : sudo systemctl restart forgejo
```

> Le reverse proxy nginx est **déjà prêt** pour les gros uploads LFS : `client_max_body_size 500m`, les timeouts `600s` et `proxy_request_buffering off` configurés en §6.3 couvrent exactement ce besoin. Rien à modifier côté nginx.
> Pour autoriser des objets > 500 Mo, augmente `client_max_body_size` dans `/etc/nginx/sites-available/forgejo` puis `sudo nginx -t && sudo systemctl reload nginx`.

### 12.3 Vérifier que LFS est actif

Depuis le Pi (un dépôt doit déjà exister) :

```bash
curl -I https://<SOUS_DOMAINE>.duckdns.org:8181/<utilisateur>/<depot>.git/info/lfs/objects/batch
# HTTP/2 401 ou 404  ← LFS écoute (OK)
# connection refused / 502  ← LFS inactif
```

Dans l'interface : **Site Administration → Configuration** affiche l'état du serveur LFS.

### 12.4 Activer LFS côté client (poste de dev)

Une seule fois par machine :

```bash
sudo apt install git-lfs      # WSL Ubuntu/Debian
git lfs install
```

Dans le dépôt, déclarer les types de fichiers à suivre par LFS (exemple projet UE5) :

```bash
git lfs track "*.uasset"
git lfs track "*.umap"
git lfs track "*.fbx"
git lfs track "*.png"
git lfs track "*.jpg"
git lfs track "*.tga"
git lfs track "*.wav"
git lfs track "*.mp3"
git lfs track "*.ogg"

git add .gitattributes
git commit -m "Enable Git LFS for binary assets"
git push                      # auth = utilisateur Forgejo + access token (§11)
```

Le `.gitattributes` généré contient :

```
*.uasset filter=lfs diff=lfs merge=lfs -text
*.umap   filter=lfs diff=lfs merge=lfs -text
*.fbx    filter=lfs diff=lfs merge=lfs -text
*.png    filter=lfs diff=lfs merge=lfs -text
```

### 12.5 Commandes LFS au quotidien

```bash
git lfs status      # fichiers LFS en attente de push
git lfs ls-files    # lister les fichiers suivis par LFS
git lfs pull        # récupérer les objets manquants après un clone
git lfs prune       # purger les vieux objets LFS locaux

# Espace LFS côté serveur (sur le Pi) :
du -sh /opt/forgejo/data/git/lfs
```

> **Espace disque Pi 5** : les objets LFS s'accumulent vite (compte 2–10 Go pour un projet UE5). Surveille `df -h` régulièrement ; si la carte SD est juste, déplace le volume `./data` (ou monte un disque externe) et adapte le bind-mount du `docker-compose.yml`.

---

## 13. Exploitation au quotidien

| Action               | Commande                                  |
|----------------------|-------------------------------------------|
| Démarrer             | `sudo systemctl start forgejo`            |
| Arrêter              | `sudo systemctl stop forgejo`             |
| Redémarrer           | `sudo systemctl restart forgejo`          |
| Statut               | `sudo systemctl status forgejo`           |
| Logs Forgejo (Docker) | `docker logs forgejo -f`                 |
| Logs Forgejo (fichier) | `sudo tail -f /opt/forgejo/data/gitea/log/gitea.log` |
| Logs PostgreSQL      | `docker logs forgejo-db -f`               |
| Logs nginx (Forgejo) | `sudo tail -f /var/log/nginx/forgejo-{access,error}.log` |
| Logs fail2ban        | `sudo tail -f /var/log/fail2ban.log`      |

---

## 14. Bannissements fail2ban — consulter et lever

### Voir l'état d'une jail

```bash
sudo fail2ban-client status forgejo   # ou sshd
```

Exemple de sortie :

```
Status for the jail: forgejo
|- Filter
|  |- Currently failed:	0
|  `- File list:	/opt/forgejo/data/gitea/log/gitea.log
`- Actions
   |- Currently banned:	1
   `- Banned IP list:	203.0.113.42
```

### Lever un bannissement

```bash
# Lever l'IP dans la jail forgejo
sudo fail2ban-client set forgejo unbanip 203.0.113.42

# Lever l'IP dans toutes les jails simultanément
sudo fail2ban-client unban 203.0.113.42

# Lever toutes les IPs bannies dans toutes les jails
sudo fail2ban-client unban --all
```

### Ajouter une IP en liste blanche permanente

Éditer `/etc/fail2ban/jail.d/local.conf`, section `[DEFAULT]` :

```ini
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16 10.0.0.0/8 <IP_A_WHITELIST>
```

Puis :

```bash
sudo systemctl restart fail2ban
```

### Paramètres actuels

Voir §7.2 — résumé :

| Paramètre      | Valeur  | Effet                                                    |
|----------------|---------|----------------------------------------------------------|
| `maxretry`     | **5**   | 5 échecs autorisés avant ban                             |
| `findtime`     | **10m** | Fenêtre dans laquelle les 5 échecs sont comptés          |
| `bantime`      | **10m** | Durée du ban une fois l'IP bannie                        |
| `ignoreip`     | LAN + localhost | Aucun ban possible pour les connexions venant du LAN |

---

## 15. Mises à jour

### Forgejo

```bash
cd /opt/forgejo
docker compose pull
sudo systemctl restart forgejo
```

### Certificat

Rien à faire — acme.sh renouvelle automatiquement (cron daily à `18:19`, déclenchement effectif ~T-30 jours).

### fail2ban / nginx / système

`sudo apt-get update && sudo apt-get upgrade` comme d'habitude.

---

## 16. Dépannage

### Fermer un port dans UFW

```bash
sudo ufw delete allow <PORT>/tcp
sudo ufw status
```

### Désactiver un site Nginx

Liens symboliques dans `/etc/nginx/sites-enabled/`. Désactiver sans supprimer :

```bash
sudo rm /etc/nginx/sites-enabled/<NOM>
sudo nginx -t && sudo systemctl reload nginx
```

Réactiver :

```bash
sudo ln -s /etc/nginx/sites-available/<NOM> /etc/nginx/sites-enabled/<NOM>
sudo systemctl reload nginx
```

### Vérifier les ports ouverts

Depuis le Pi :

```bash
sudo ss -tlnp                 # tous les services en écoute
sudo ss -tlnp | grep 8181     # focus sur un port
```

Depuis l'extérieur (Internet) :

```bash
nmap -Pn -p 8181 <SOUS_DOMAINE>.duckdns.org
```

### Vérifier que le certif est trusté

```bash
echo | openssl s_client -connect <SOUS_DOMAINE>.duckdns.org:8181 \
       -servername <SOUS_DOMAINE>.duckdns.org -CApath /etc/ssl/certs 2>&1 \
       | grep -E 'Verify return code|subject='
```

→ `Verify return code: 0 (ok)` attendu.

### Tester le filtre fail2ban contre les logs en place

```bash
sudo fail2ban-regex /opt/forgejo/data/gitea/log/gitea.log /etc/fail2ban/filter.d/forgejo.conf
```

### Certificat expiré alors que le renouvellement auto est configuré

Symptôme navigateur : `NET::ERR_CERT_DATE_INVALID`, cert expiré à une date passée.
**Cause la plus probable ici : le Pi était éteint pendant la fenêtre de renouvellement**
(acme.sh déclenche ~T-30 j via le cron daily 18:19 — si la machine ne tourne pas ces
jours-là, le renouvellement ne peut pas avoir lieu). acme.sh, le token DuckDNS et le
cron ne sont PAS en cause : un renouvellement manuel le prouve immédiatement.

Diagnostic :

```bash
# Le certif servi + ses dates
sudo openssl x509 -in /etc/nginx/ssl/forgejo.crt -noout -subject -dates

# La machine tournait-elle pendant la fenêtre ? (journal vide sur la période = éteinte)
sudo journalctl --list-boots | tail
sudo journalctl --since "<AAAA-MM-01>" --until "<AAAA-MM-30>" | head

# État acme.sh (colonne Renew = prochaine date de renouvellement prévue)
sudo /root/.acme.sh/acme.sh --list
```

Correctif — renouvellement manuel forcé (le token DuckDNS est déjà persisté dans
`/root/.acme.sh/account.conf` comme `SAVED_DuckDNS_Token`, inutile de le ré-exporter) :

```bash
sudo /root/.acme.sh/acme.sh --renew -d <SOUS_DOMAINE>.duckdns.org --ecc --force
# installe le nouveau cert dans /etc/nginx/ssl/forgejo.{crt,key} et recharge nginx (reload cmd intégré)
```

Vérifier que nginx sert bien le nouveau cert, puis Ctrl+Shift+R côté navigateur :

```bash
echo | openssl s_client -connect 127.0.0.1:8181 -servername <SOUS_DOMAINE>.duckdns.org 2>/dev/null \
  | openssl x509 -noout -dates
```

Rattraper tous les domaines en retard d'un coup (utile si plusieurs sous-domaines sont gérés par acme.sh) :
`sudo /root/.acme.sh/acme.sh --cron`.

> Marge : un cert Let's Encrypt a ~30 j de rab après la date de renouvellement, donc une
> extinction de quelques jours est sans conséquence — c'est un mois complet hors ligne qui
> a fait expirer le cert. Le cron redirige sa sortie vers `/dev/null` : les échecs sont
> silencieux (cf. amélioration optionnelle : notification d'échec).

---

## 17. Structure des fichiers

```
/opt/forgejo/
├── docker-compose.yml      # définition des services          [versionné]
├── .env-template           # gabarit de configuration         [versionné]
├── .gitignore              # exclut .env, data/, postgres-data/ [versionné]
├── README.md               # présentation du dépôt            [versionné]
├── SETUP-K3S.md            # cluster k3s + runners Actions    [versionné]
├── k3s/                    # manifestes des runners           [versionné]
├── .forgejo/workflows/     # workflow de démonstration        [versionné]
├── .env                    # domaine + credentials PostgreSQL (chmod 600, JAMAIS versionné)
├── data/                   # données Forgejo (non versionné)
│   └── gitea/
│       ├── conf/app.ini    # config Forgejo (SECRET_KEY, LFS_JWT_SECRET…)
│       ├── lfs/            # objets Git LFS (binaires)
│       └── log/gitea.log   # log lu par fail2ban
├── postgres-data/          # données PostgreSQL (non versionné)
└── SETUP.md                # ce fichier                       [versionné]

/etc/nginx/
├── nginx.conf                              # server_tokens off
├── conf.d/00-rate-limit.conf               # zone forgejo_login
├── sites-available/forgejo                 # vhost Forgejo
├── sites-enabled/forgejo → ../sites-available/forgejo
└── ssl/                                    # forgejo.{crt,key} (acme.sh)

/etc/fail2ban/
├── filter.d/forgejo.conf                   # regex login échoué
└── jail.d/local.conf                       # jails sshd + forgejo + DEFAULT

/etc/systemd/system/forgejo.service         # unit systemd

/root/.acme.sh/                             # acme.sh + certs sources + token DuckDNS
~/duckdns/update.sh                         # refresh IP DuckDNS (cron 5 min)
```
