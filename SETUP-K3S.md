# Forgejo Actions — cluster de runners k3s

Guide pour ajouter une **CI auto-hébergée** à l'instance Forgejo montée par [SETUP.md](SETUP.md) : un cluster **k3s mono-nœud** qui héberge les runners Forgejo Actions. Conçu et validé sur un Raspberry Pi 5 (Debian 12, ARM64) partagé avec d'autres services.

À la fin, un `git push` déclenche un job qui tourne sur la machine, sans aucun runner cloud et sans exposition réseau supplémentaire.

## Sommaire

1. [Architecture](#1-architecture)
2. [Prérequis — le piège du cgroup mémoire](#2-prérequis--le-piège-du-cgroup-mémoire)
3. [Installer k3s](#3-installer-k3s)
4. [Ouvrir le réseau des pods dans UFW](#4-ouvrir-le-réseau-des-pods-dans-ufw)
5. [Activer Forgejo Actions](#5-activer-forgejo-actions)
6. [Token d'enregistrement et Secret](#6-token-denregistrement-et-secret)
7. [Déployer le runner](#7-déployer-le-runner)
8. [Vérifier de bout en bout](#8-vérifier-de-bout-en-bout)
9. [Exploitation au quotidien](#9-exploitation-au-quotidien)
10. [Dimensionner et scaler](#10-dimensionner-et-scaler)
11. [Sécurité](#11-sécurité)
12. [Dépannage](#12-dépannage)
13. [Désinstallation](#13-désinstallation)
14. [Améliorations possibles](#14-améliorations-possibles)

---

## 1. Architecture

```
                    ┌─────────────────────── serveur ───────────────────────┐
                    │                                                        │
  git push ──►  nginx :8181 ──► Forgejo (docker-compose) ──► PostgreSQL      │
                    │              ▲                                         │
                    │              │ le runner interroge la forge en HTTPS   │
                    │              │ sur le LAN (hostAliases)                │
                    │   ┌──────────┴─────────── k3s ────────────────────┐    │
                    │   │  namespace forgejo-actions                    │    │
                    │   │  ┌─ pod forgejo-runner-0 ──────────────────┐  │    │
                    │   │  │  act_runner  ──socket unix──►  dind     │  │    │
                    │   │  │                                 └─ conteneurs   │
                    │   │  │                                    de job   │   │
                    │   │  └─────────────────────────────────────────┘  │    │
                    │   └───────────────────────────────────────────────┘    │
                    └────────────────────────────────────────────────────────┘
```

Deux choses à retenir :

- **Le runner est un client sortant.** Il interroge Forgejo, personne ne l'appelle. Aucun port supplémentaire n'est ouvert sur la box : l'exposition publique reste le seul `8181/tcp` de [SETUP.md §9](SETUP.md#9-box--routeur--redirection-du-port-8181).
- **Les jobs tournent dans un Docker imbriqué** (`dind`), pas dans le Docker de l'hôte ni dans containerd. Un job ne voit donc jamais les conteneurs Forgejo ou les autres services.

Ressources mesurées au repos : **dind ~126 Mio, act_runner ~23 Mio**, plus ~600 Mio pour le plan de contrôle k3s.

---

## 2. Prérequis — le piège du cgroup mémoire

> ⚠️ **À faire en premier, un redémarrage est nécessaire.**

kubelet a besoin du contrôleur cgroup `memory` pour appliquer la moindre limite RAM. Or le firmware du Raspberry Pi injecte `cgroup_disable=memory` dans la ligne de commande du noyau — et ce paramètre **n'apparaît pas** dans `cmdline.txt`, ce qui rend le diagnostic déroutant.

```bash
cat /sys/fs/cgroup/cgroup.controllers
# cpuset cpu io pids          ← pas de "memory" : à corriger
# cpuset cpu io memory pids   ← correct
```

Ajouter les paramètres en **fin de l'unique ligne** de `/boot/firmware/cmdline.txt` (ils arrivent après ceux du firmware et le neutralisent) :

```bash
sudo cp -a /boot/firmware/cmdline.txt /boot/firmware/cmdline.txt.bak
NEW="$(sudo cat /boot/firmware/cmdline.txt) cgroup_enable=memory cgroup_memory=1"
printf '%s' "$NEW" | sudo tee /boot/firmware/cmdline.txt >/dev/null
sudo reboot
```

> Le fichier doit rester **sur une seule ligne**. Vérifier avant de redémarrer : `wc -l < /boot/firmware/cmdline.txt` doit afficher `0` (une seule ligne sans retour final) et la ligne doit être lisible en entier.

Au retour, `memory` doit apparaître dans `cgroup.controllers`. Sinon : restaurer `cmdline.txt.bak` et redémarrer.

Autres prérequis : Docker et Forgejo déjà en place ([SETUP.md](SETUP.md)), `gettext-base` pour `envsubst` (`sudo apt-get install -y gettext-base`).

---

## 3. Installer k3s

```bash
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="server \
  --disable traefik --disable servicelb \
  --node-name <NOM_DU_NOEUD> \
  --write-kubeconfig-mode 640" sh -s -
```

| Choix | Pourquoi |
|---|---|
| `--disable traefik` | nginx fronte déjà tout, aucun Ingress n'est nécessaire |
| `--disable servicelb` | pas de LoadBalancer sur un nœud unique |
| `metrics-server` **conservé** | ~65 Mio pour disposer de `kubectl top` — indispensable pour piloter la RAM sur une petite machine |
| `local-path` **conservé** | fournit les volumes persistants du runner |

Rendre `kubectl` utilisable sans `sudo` :

```bash
mkdir -p ~/.kube
sudo install -o $USER -g $USER -m 600 /etc/rancher/k3s/k3s.yaml ~/.kube/config
echo 'export KUBECONFIG="$HOME/.kube/config"' >> ~/.bashrc
export KUBECONFIG="$HOME/.kube/config"

kubectl get nodes          # <NOM_DU_NOEUD>  Ready  control-plane
```

> Sans `KUBECONFIG`, le `kubectl` de k3s lit `/etc/rancher/k3s/k3s.yaml`, illisible par un utilisateur normal → `permission denied`.

---

## 4. Ouvrir le réseau des pods dans UFW

UFW arrive par défaut en `deny (routed)`, ce qui coupe le trafic sortant des pods (impossible de cloner un dépôt ou d'installer des dépendances dans un job) :

```bash
sudo ufw allow from 10.42.0.0/16 to any comment 'k3s pods'
sudo ufw allow from 10.43.0.0/16 to any comment 'k3s services'
```

Rien d'autre à ouvrir : le port `8181` de nginx est déjà autorisé et écoute sur toutes les interfaces, donc les pods y accèdent par l'IP LAN du nœud. L'API k3s (`6443`) reste couverte par le `deny (incoming)` par défaut et n'est pas redirigée par la box.

Vérifier :

```bash
kubectl run net-test --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  curl -sS -m 10 -o /dev/null -w 'egress HTTP %{http_code}\n' https://code.forgejo.org
```

> N'utilise pas `busybox` pour ce test : son `wget` échoue sur certains sites HTTPS pour des raisons de TLS, pas de pare-feu — un faux négatif classique.

Si l'egress échoue vraiment, ajouter `sudo ufw route allow from 10.42.0.0/16`.

---

## 5. Activer Forgejo Actions

Deux variables dans le `docker-compose.yml` de Forgejo (déjà présentes dans ce dépôt, cf. [SETUP.md §4](SETUP.md#4-docker-composeyml)) :

```yaml
      - FORGEJO__actions__ENABLED=true
      - FORGEJO__actions__DEFAULT_ACTIONS_URL=https://code.forgejo.org
```

```bash
cd /opt/forgejo && docker compose up -d
docker exec forgejo grep -A4 '^\[actions\]' /data/gitea/conf/app.ini
```

> ⚠️ Dès qu'un runner existe, **tous les workflows déjà présents dans tes dépôts deviennent actifs** et se déclencheront au prochain push. Vérifie ce que contiennent tes `.forgejo/workflows/` et `.github/workflows/` avant d'aller plus loin.

---

## 6. Token d'enregistrement et Secret

Le token ne doit **jamais** finir dans un fichier versionné. Il est généré puis passé directement à Kubernetes, sans transiter par le disque :

```bash
kubectl apply -f k3s/00-namespace.yaml       # crée le namespace d'abord

TOKEN=$(docker exec -u git forgejo forgejo actions generate-runner-token)
kubectl -n forgejo-actions create secret generic forgejo-runner-token \
  --from-literal=token="$TOKEN"
unset TOKEN
```

C'est un token **de niveau instance** : il vaut pour tous les dépôts et peut enregistrer plusieurs runners. Équivalent dans l'interface : *Site Administration → Actions → Runners → Create new runner*.

---

## 7. Déployer le runner

```bash
cd /opt/forgejo
./k3s/apply.sh
```

Le script lit `.env`, substitue `${FORGEJO_DOMAIN}` et `${NODE_LAN_IP}` dans les manifestes, puis applique. Les fichiers versionnés ne contiennent donc aucune valeur propre à un environnement.

| Fichier | Contenu |
|---|---|
| `k3s/00-namespace.yaml` | namespace `forgejo-actions`, `ResourceQuota`, `LimitRange`, `NetworkPolicy` |
| `k3s/10-runner-config.yaml` | `config.yaml` d'act_runner (capacité, timeouts, cache) |
| `k3s/20-runner-statefulset.yaml` | le runner lui-même |
| `k3s/apply.sh` | substitution + `kubectl apply` |

### Ce qui compose le pod

| Conteneur | Rôle | Limites |
|---|---|---|
| `dind` (sidecar natif) | démon Docker qui exécute les jobs | 2 CPU / **2 Gio** |
| `register` (init) | enregistre le runner au tout premier démarrage | — |
| `runner` | act_runner, interroge Forgejo et pilote dind | 0,5 CPU / 256 Mio |

Quatre décisions qui méritent une explication :

- **StatefulSet, pas Deployment.** `/data` est un volume persistant, donc le runner s'enregistre une seule fois et garde une identité stable. Avec un `emptyDir`, chaque redémarrage de pod créerait un nouveau runner et laisserait une traînée d'entrées « offline » dans l'administration Forgejo.
- **`hostAliases`.** Le runner cible `https://<SOUS_DOMAINE>.duckdns.org:8181` mais ce nom est résolu vers l'IP LAN du serveur. Le certificat Let's Encrypt reste valide (même nom d'hôte) et le trafic ne sort jamais du réseau local. Sans cela il faudrait compter sur le NAT loopback de la box, qui n'est pas garanti — et les pods k3s ne peuvent de toute façon pas joindre le bridge Docker de Forgejo.
- **Socket unix plutôt que TCP.** Le runner parle à dind via `/var/run/docker.sock` partagé par un `emptyDir`. Docker déprécie l'écoute TCP sans authentification et annonce sa suppression.
- **La limite de 2 Gio est sur `dind`, pas sur le runner.** Les conteneurs de job sont des enfants du démon Docker : leur mémoire est comptée dans **son** cgroup. C'est donc ce plafond qui borne réellement un build.

---

## 8. Vérifier de bout en bout

```bash
kubectl -n forgejo-actions get pods            # forgejo-runner-0   2/2   Running
kubectl -n forgejo-actions logs forgejo-runner-0 -c runner
# → "declared successfully", "[poller 0] launched", "[poller 1] launched"
```

Dans Forgejo : **Site Administration → Actions → Runners** — le runner doit apparaître **Idle** avec les labels `docker`, `arm64`, `ubuntu-latest`.

Puis un vrai job. Copier [`.forgejo/workflows/ci-demo.yml`](.forgejo/workflows/ci-demo.yml) dans un dépôt de la forge et pousser sur `main` :

```yaml
jobs:
  smoke:
    runs-on: docker
    steps:
      - run: echo "architecture : $(uname -m)"   # attendu : aarch64
      - uses: actions/checkout@v4
```

Onglet **Actions** du dépôt → job vert. Repères de la première exécution mesurée : **62 s au total**, dont ~32 s de téléchargement de `node:22-bookworm` (les suivantes réutilisent le cache d'images de dind).

---

## 9. Exploitation au quotidien

| Action | Commande |
|---|---|
| État du cluster | `kubectl get nodes` |
| État du runner | `kubectl -n forgejo-actions get pods` |
| Logs du runner | `kubectl -n forgejo-actions logs forgejo-runner-0 -c runner -f` |
| Logs du démon Docker | `kubectl -n forgejo-actions logs forgejo-runner-0 -c dind -f` |
| Consommation réelle | `kubectl top pod -n forgejo-actions --containers` |
| Budget consommé | `kubectl -n forgejo-actions get resourcequota` |
| Redémarrer le runner | `kubectl -n forgejo-actions delete pod forgejo-runner-0` |
| Réappliquer la config | `./k3s/apply.sh` |
| Arrêter la CI sans désinstaller | `kubectl -n forgejo-actions scale statefulset forgejo-runner --replicas=0` |
| Arrêter k3s entièrement | `sudo systemctl stop k3s` |

Le cache d'images de dind grossit avec le temps. Pour le purger :

```bash
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- docker system prune -af
```

---

## 10. Dimensionner et scaler

La configuration livrée vise **1 développeur en usage courant, une dizaine en pic** :

| Paramètre | Valeur | Effet |
|---|---|---|
| `replicas` | 1 | un seul pod runner |
| `capacity` | 2 | 2 jobs simultanés |
| `ResourceQuota` | 2,5 Gio / 3 CPU | plafond dur de toute la CI |

Sur une machine à 4 cœurs, le facteur limitant est le CPU, pas le nombre de runners : au-delà de ~4 jobs simultanés les builds se ralentissent mutuellement. Les jobs excédentaires **font la queue**, ce qui est le comportement souhaitable — mieux vaut attendre que faire tomber la forge.

Pour encaisser un pic (4 jobs simultanés), il faut **deux gestes, pas un** :

```bash
# 1. relever le plafond, sinon le 2ᵉ pod reste Pending (quota dépassé)
kubectl -n forgejo-actions patch resourcequota ci-budget \
  --type merge -p '{"spec":{"hard":{"limits.memory":"5Gi","requests.memory":"1536Mi"}}}'
# 2. ajouter une réplique
kubectl -n forgejo-actions scale statefulset forgejo-runner --replicas=2
```

Chaque réplique s'enregistre toute seule sous son propre nom (`forgejo-runner-1`) et obtient ses propres volumes. Pour revenir en arrière : `--replicas=1`, puis remettre le quota d'origine.

> Sur une machine partagée, vérifier `free -h` avant de scaler. Un service gourmand allumé en même temps qu'un build lourd peut faire basculer la machine sur le swap.

---

## 11. Sécurité

**Le conteneur `dind` est privilégié**, ce qui équivaut à un accès root sur le nœud. C'est inhérent à l'exécution de conteneurs de job : il n'y a pas de version « non privilégiée » de ce montage qui reste simple et fiable. Conséquence pratique :

> **N'exécute des workflows que depuis des dépôts de confiance.** Un workflow malveillant sur cette instance peut prendre le contrôle de la machine. C'est acceptable sur une forge privée dont les comptes sont créés à la main par l'administrateur (`DISABLE_REGISTRATION = true`, cf. [SETUP.md §10.5](SETUP.md#105-gérer-les-utilisateurs-cli-admin)) ; ça ne l'est pas sur une forge ouverte à l'inscription.

Les garde-fous en place :

| Mesure | Effet |
|---|---|
| `NetworkPolicy default-deny-ingress` | aucun pod du cluster ne peut joindre le démon Docker du runner. L'entrypoint de l'image dind ouvre systématiquement `tcp://0.0.0.0:2375` sans authentification quand TLS est désactivé, et on ne peut pas le lui retirer — on ferme donc l'accès au niveau réseau |
| `ResourceQuota` | la CI ne peut pas affamer les autres services de la machine |
| Aucun Ingress, aucun NodePort | le runner est un pur client sortant |
| API k3s non exposée | `6443` bloqué par UFW en entrée, non redirigé par la box |
| Token hors dépôt | uniquement dans un Secret Kubernetes |

---

## 12. Dépannage

### Le pod reste `Init:CrashLoopBackOff`, dind dit `address already in use`

```
failed to load listeners: listen tcp 127.0.0.1:2375: bind: address already in use
```

`dockerd-entrypoint.sh` ajoute **déjà** `--host=unix:///var/run/docker.sock` et `--host=tcp://0.0.0.0:2375` lorsque `DOCKER_TLS_CERTDIR` est vide. Ajouter soi-même un `--host` crée un doublon. Solution : ne passer **aucun** `--host` au conteneur dind.

### Le runner boucle sur `permission denied` sur le socket Docker

```
cannot ping the docker daemon. is it running? permission denied while trying to
connect to the Docker daemon socket at unix:///var/run/docker.sock
```

L'image du runner tourne en uid/gid 1000 alors que dind crée le socket en `root:2375` (le gid du groupe `docker` de l'image dind). Il manque le groupe supplémentaire dans le pod :

```yaml
      securityContext:
        supplementalGroups: [2375]
```

Vérifier les deux côtés en cas de doute :

```bash
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- ls -ln /var/run/docker.sock
docker run --rm --entrypoint sh code.forgejo.org/forgejo/runner:6 -c id
```

### Le runner ne voit pas la forge

```bash
kubectl -n forgejo-actions exec forgejo-runner-0 -c runner -- \
  wget -qO- https://<SOUS_DOMAINE>.duckdns.org:8181/api/v1/version
```

- Erreur TLS → le nom d'hôte des `hostAliases` ne correspond pas à celui du certificat.
- Timeout → `NODE_LAN_IP` est faux dans `.env`, ou nginx n'écoute pas sur toutes les interfaces.

### Un job échoue au `docker pull`

Egress des pods bloqué : voir [§4](#4-ouvrir-le-réseau-des-pods-dans-ufw). Tester avec `curl`, pas avec `busybox wget`.

### Le pod reste `Pending`

```bash
kubectl -n forgejo-actions describe pod forgejo-runner-0 | tail -20
```

Le plus souvent : `ResourceQuota` dépassé (voir [§10](#10-dimensionner-et-scaler)) ou volume non provisionné.

### Des runners « offline » s'accumulent dans l'interface

Symptôme d'un `/data` non persistant. Le StatefulSet livré ici l'évite ; les entrées mortes se suppriment dans *Site Administration → Actions → Runners*.

---

## 13. Désinstallation

```bash
# Retirer seulement la CI, garder le cluster
kubectl delete namespace forgejo-actions

# Retirer k3s entièrement
sudo /usr/local/bin/k3s-uninstall.sh
sudo ufw delete allow from 10.42.0.0/16
sudo ufw delete allow from 10.43.0.0/16

# Revenir au noyau d'origine (facultatif)
sudo cp -a /boot/firmware/cmdline.txt.bak /boot/firmware/cmdline.txt && sudo reboot
```

Pour désactiver aussi le moteur CI : retirer les deux variables `FORGEJO__actions__*` du `docker-compose.yml` puis `docker compose up -d`.

---

## 14. Améliorations possibles

- **Cache des actions** (`cache.enabled: true` dans `k3s/10-runner-config.yaml`) : accélère nettement les workflows qui réinstallent des dépendances. Demande de vérifier que les conteneurs de job joignent bien le serveur de cache du runner — laissé désactivé par défaut pour éviter un mode de panne silencieux.
- **Runners par label** : un second StatefulSet avec d'autres labels et d'autres images permet de router les jobs (`runs-on: gros-build`) vers des runners aux limites différentes.
- **Analyse SonarQube** : une fois un serveur Sonar déployé sur le LAN, un job `runs-on: docker` avec `SONAR_HOST_URL` et `SONAR_TOKEN` en secrets de dépôt suffit. Point à vérifier à ce moment-là : la disponibilité d'une image **arm64** pour le scanner, ou le repli sur un conteneur JDK arm64 qui télécharge le scanner.
