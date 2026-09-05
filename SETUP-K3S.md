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
10. [Visualiser et superviser le cluster](#10-visualiser-et-superviser-le-cluster)
11. [Ajouter des runners](#11-ajouter-des-runners)
12. [Sécurité](#12-sécurité)
13. [Dépannage](#13-dépannage)
14. [Désinstallation](#14-désinstallation)
15. [Améliorations possibles](#15-améliorations-possibles)

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

Ressources mesurées au repos : **dind ~35-130 Mio, act_runner ~25 Mio au démarrage**, plus ~600 Mio pour le plan de contrôle k3s. Le tas de act_runner grossit ensuite tant qu'il n'y a pas de pression mémoire — d'où le `GOMEMLIMIT` de la [§7](#7-déployer-le-runner).

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
kubectl apply -f k3s/runner/00-namespace.yaml       # crée le namespace d'abord

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
./k3s/apply.sh              # équivaut à : ./k3s/apply.sh runner
```

Le script lit `.env`, substitue `${FORGEJO_DOMAIN}` et `${NODE_LAN_IP}` dans les manifestes du composant demandé, puis applique. Les composants sont les sous-dossiers de `k3s/` — `runner` (défaut) et `sonarqube` (cf. [SETUP-SONARQUBE.md](SETUP-SONARQUBE.md)). Les fichiers versionnés ne contiennent donc aucune valeur propre à un environnement.

| Fichier | Contenu |
|---|---|
| `k3s/runner/00-namespace.yaml` | namespace `forgejo-actions`, `ResourceQuota`, `LimitRange`, `NetworkPolicy` |
| `k3s/runner/10-runner-config.yaml` | `config.yaml` d'act_runner (capacité, timeouts, cache) |
| `k3s/runner/20-runner-statefulset.yaml` | le runner lui-même |
| `k3s/apply.sh` | substitution des variables de `.env` + `kubectl apply`, pour un composant donné |

### Ce qui compose le pod

| Conteneur | Rôle | Limites |
|---|---|---|
| `dind` (sidecar natif) | démon Docker qui exécute les jobs | 2 CPU / **2 Gio** |
| `register` (init) | enregistre le runner au tout premier démarrage | — |
| `runner` | act_runner, interroge Forgejo et pilote dind | 2 CPU / 1 Gio |

Cinq décisions qui méritent une explication :

- **StatefulSet, pas Deployment.** `/data` est un volume persistant, donc le runner s'enregistre une seule fois et garde une identité stable. Avec un `emptyDir`, chaque redémarrage de pod créerait un nouveau runner et laisserait une traînée d'entrées « offline » dans l'administration Forgejo.
- **`hostAliases`.** Le runner cible `https://<SOUS_DOMAINE>.duckdns.org:8181` mais ce nom est résolu vers l'IP LAN du serveur. Le certificat Let's Encrypt reste valide (même nom d'hôte) et le trafic ne sort jamais du réseau local. Sans cela il faudrait compter sur le NAT loopback de la box, qui n'est pas garanti — et les pods k3s ne peuvent de toute façon pas joindre le bridge Docker de Forgejo.
- **Socket unix plutôt que TCP.** Le runner parle à dind via `/var/run/docker.sock` partagé par un `emptyDir`. Docker déprécie l'écoute TCP sans authentification et annonce sa suppression.
- **`GOMEMLIMIT` sur le conteneur runner.** act_runner est écrit en Go : sans pression mémoire, son tas grossit sans jamais être rendu au système. Mesuré ici : ~25 Mio au démarrage, ~253 Mio après 42 minutes **à vide**, puis OOM kill. `GOMEMLIMIT` force le ramasse-miettes bien avant le plafond du cgroup ; régler un plafond sans lui ne fait que repousser l'échéance.
  Le calibrer **trop bas est pire que l'OOM** : si le tas colle en permanence au seuil, le GC tourne sans discontinuer et consomme tout le quota CPU. Le runner ne plante plus, il se traîne — voir [§13](#un-job-traîne-indéfiniment-sur--set-up-job-). Retenir : `GOMEMLIMIT` ≈ 75 % de `limits.memory`, et une limite CPU assez large pour que le GC ne prenne pas la place du travail utile. Ici : `1 Gio` / `768MiB` / `2` CPU.
- **La limite de 2 Gio est sur `dind`, pas sur le runner.** Les conteneurs de job sont des enfants du démon Docker : leur mémoire est comptée dans **son** cgroup. C'est donc ce plafond qui borne réellement un build.
- **Le runner n'est pas qu'un sondeur.** Il clone les actions référencées par le workflow, les recopie dans le conteneur de job (`docker cp`) et relaie les logs. Tout ce travail est *hors* du conteneur de job : le serrer sur le CPU ralentit chaque étape de préparation, y compris celles qui affichent un conteneur de job inactif.

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
| Interface de navigation | `k9s -n forgejo-actions` (cf. [§10](#10-visualiser-et-superviser-le-cluster)) |
| Arrêter la CI sans désinstaller | `kubectl -n forgejo-actions scale statefulset forgejo-runner --replicas=0` |
| Arrêter k3s entièrement | `sudo systemctl stop k3s` |

Le cache d'images de dind grossit avec le temps. Pour le purger :

```bash
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- docker system prune -af
```

---

## 10. Visualiser et superviser le cluster

### k9s — l'interface du quotidien

`k9s` est un navigateur de cluster en terminal : il n'a **aucun composant résident**, il ne coûte donc rien en RAM quand tu ne l'utilises pas. C'est le bon choix sur une petite machine.

Il n'est pas dans les dépôts Debian, c'est un binaire à poser à la main :

```bash
VER=$(curl -sS https://api.github.com/repos/derailed/k9s/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
cd /tmp
curl -sSLO "https://github.com/derailed/k9s/releases/download/${VER}/k9s_Linux_arm64.tar.gz"
curl -sSLO "https://github.com/derailed/k9s/releases/download/${VER}/checksums.sha256"
grep 'k9s_Linux_arm64.tar.gz$' checksums.sha256 | sha256sum -c -    # doit afficher : OK
tar xzf k9s_Linux_arm64.tar.gz k9s
sudo install -o root -g root -m 755 k9s /usr/local/bin/k9s
rm -f k9s k9s_Linux_arm64.tar.gz checksums.sha256
k9s version
```

> Vérifie toujours le checksum : c'est un binaire téléchargé hors gestionnaire de paquets, donc sans signature APT pour te protéger.

Lancement : `k9s`. Sur un terminal étroit, `k9s -n forgejo-actions` démarre directement sur le bon namespace.

| Touche | Effet |
|---|---|
| `:pods` `:svc` `:pvc` `:no` | changer de type de ressource (`:` puis le nom) |
| `0` / `1` … | filtrer par namespace (`0` = tous) |
| `l` | logs du conteneur sélectionné |
| `s` | ouvrir un shell dedans |
| `d` / `y` | décrire / voir le YAML |
| `ctrl-d` | supprimer un pod (il sera recréé) |
| `:pu` | *pulses* — vue d'ensemble animée du cluster |
| `?` puis `:q` | aide, puis quitter |

Un pod à deux conteneurs comme le runner demande de choisir lequel : sélectionne le pod, `Entrée` pour descendre dans ses conteneurs, puis `l` pour les logs.

### Ce que la supervision intégrée ne fait pas

`metrics-server` ne fournit que **l'instantané**. Aucun historique n'est conservé, aucune alerte n'est possible : si la machine sature pendant la nuit, rien ne permettra de remonter le temps. Pour du diagnostic à chaud c'est suffisant, pour de la supervision ça ne l'est pas.

Trois façons d'aller plus loin, par coût croissant :

| Approche | Coût RAM | Ce que ça apporte |
|---|---|---|
| `kubectl top` + k9s | ~0 | instantané, diagnostic à chaud |
| Agent de métriques vers une base existante (Telegraf → InfluxDB) | ~50 Mio | historique et alertes sans déployer une seconde base |
| Prometheus + Grafana dans le cluster | 600 Mio – 1 Gio | supervision complète, mais mange le budget réservé à la CI |

Sur un serveur qui héberge déjà une base de séries temporelles, la deuxième ligne est le meilleur rapport valeur/RAM — inutile d'empiler un second système de stockage de métriques.

### Suivre la CI elle-même

Pour l'état des runners et les logs de jobs, l'interface de référence reste **Forgejo** : *Site Administration → Actions → Runners* pour l'état (Idle / Active, dernier contact), et l'onglet *Actions* de chaque dépôt pour le détail des exécutions.

---

## 11. Ajouter des runners

Deux besoins différents, deux procédures.

### Cas 1 — plus de jobs en parallèle, même type de runner

C'est le cas d'un pic de charge : les jobs font la queue et tu veux les absorber plus vite. Il faut **deux gestes, pas un** — sans le premier, le nouveau pod reste `Pending`, bloqué par le quota :

Un pod runner coûte **3 Gio / 4 CPU** de plafond (dind 2 Gio + act_runner 1 Gio). Le quota livré vaut exactement cela : il faut donc le doubler avant d'ajouter la seconde réplique.

```bash
# 1. relever le plafond du namespace
kubectl -n forgejo-actions patch resourcequota ci-budget --type merge -p '{"spec":{"hard":{
  "limits.memory":"6Gi", "limits.cpu":"8",
  "requests.memory":"1280Mi", "requests.cpu":"800m"}}}'

# 2. ajouter une réplique
kubectl -n forgejo-actions scale statefulset forgejo-runner --replicas=2
```

Chaque réplique s'enregistre toute seule sous son propre nom (`forgejo-runner-1`), réutilise le Secret existant et obtient ses propres volumes. Retour en arrière : `--replicas=1` puis remettre le quota d'origine.

> Sur ce serveur (4 cœurs, 8 Gio), 6 Gio de plafond CI ne laisse plus la place à SonarQube en même temps. Ce sont des plafonds, pas des réservations — mais deux builds lourds simultanés feront basculer la machine sur le swap. Ici, l'alternative `capacity` ci-dessous est presque toujours le meilleur choix.

Pour rendre le changement permanent, éditer `replicas:` dans `k3s/runner/20-runner-statefulset.yaml` et les valeurs du `ResourceQuota` dans `k3s/runner/00-namespace.yaml`, puis `./k3s/apply.sh`.

Alternative sans nouveau pod : augmenter `runner.capacity` dans `k3s/runner/10-runner-config.yaml` (nombre de jobs simultanés **par** runner). Moins d'isolation, mais aucune RAM supplémentaire pour un second act_runner — à réserver aux jobs légers.

### Cas 2 — un runner différent (autres labels, autre image, autres limites)

C'est ce qui permet de **router les jobs** : envoyer les builds lourds sur un runner aux limites plus larges, garder les jobs rapides sur le runner par défaut.

```bash
cp k3s/runner/20-runner-statefulset.yaml k3s/runner/30-runner-heavy.yaml
```

Cinq points à modifier dans la copie — tous obligatoires, un oubli et les deux runners se marchent dessus :

| À changer | De | Vers |
|---|---|---|
| `metadata.name` (Service **et** StatefulSet) | `forgejo-runner` | `forgejo-runner-heavy` |
| `spec.serviceName` | `forgejo-runner` | `forgejo-runner-heavy` |
| `selector.matchLabels.app` et `template.metadata.labels.app` | `forgejo-runner` | `forgejo-runner-heavy` |
| `RUNNER_LABELS` | `docker:docker://…` | `gros-build:docker://<TON_IMAGE>` |
| `resources.limits` du conteneur `dind` | `2Gi` | ce que tu veux allouer |

Le `ConfigMap` et le `Secret` sont réutilisables tels quels : le token est de niveau instance et sert à enregistrer autant de runners que voulu. Si tu veux une capacité différente, crée en revanche un second ConfigMap et pointe le nouveau StatefulSet dessus.

Relever le quota en conséquence, puis appliquer — `apply.sh` prend automatiquement en compte tout nouveau fichier `k3s/runner/*.yaml` :

```bash
./k3s/apply.sh
kubectl -n forgejo-actions get pods
```

Le nouveau runner apparaît dans *Site Administration → Actions → Runners* avec ses propres labels, et un workflow le cible par `runs-on: gros-build`.

### Dimensionnement de référence

La configuration livrée vise **1 développeur en usage courant, une dizaine en pic** :

| Paramètre | Valeur | Effet |
|---|---|---|
| `replicas` | 1 | un seul pod runner |
| `capacity` | 2 | 2 jobs simultanés |
| `ResourceQuota` | 3 Gio / 4 CPU | plafond dur de toute la CI |

Sur une machine à 4 cœurs, le facteur limitant est le CPU, pas le nombre de runners : au-delà de ~4 jobs simultanés les builds se ralentissent mutuellement. Les jobs excédentaires **font la queue**, ce qui est le comportement souhaitable — mieux vaut attendre que faire tomber la forge.

> Avant de scaler sur une machine partagée, regarde `free -h` et `kubectl top nodes`. Un service gourmand allumé en même temps qu'un build lourd peut faire basculer la machine sur le swap.

---

## 12. Sécurité

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

## 13. Dépannage

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

### Le conteneur `runner` redémarre tout seul (`OOMKilled`, exit 137)

```bash
kubectl -n forgejo-actions get pod forgejo-runner-0 \
  -o jsonpath='{.status.containerStatuses[0].lastState}'
# ..."exitCode":137,"reason":"OOMKilled"...
```

Confirmer que c'est bien la limite **du conteneur** et non une pression mémoire de la machine — la distinction change complètement le correctif :

```bash
sudo dmesg -T | grep -iE 'oom-kill|Memory cgroup' | tail -5
```

- `constraint=CONSTRAINT_MEMCG` → le conteneur a dépassé **sa propre** limite.
- `constraint=CONSTRAINT_NONE` → la machine entière manquait de RAM, le noyau a choisi une victime ; c'est le dimensionnement global qu'il faut revoir, pas la limite du pod.

Dans le premier cas, pour act_runner, la cause est presque toujours la croissance du tas Go décrite en [§7](#7-déployer-le-runner) : vérifier que `GOMEMLIMIT` est bien positionné et vaut environ 75 % de `limits.memory`.

```bash
kubectl -n forgejo-actions get pod forgejo-runner-0 \
  -o jsonpath='{.spec.containers[0].env[?(@.name=="GOMEMLIMIT")].value}{"\n"}'
```

Le redémarrage est sans danger : le runner se ré-enregistre à partir de son volume persistant et reprend le travail. Un job en cours au moment du kill est en revanche perdu et doit être relancé.

### Un job traîne indéfiniment sur « Set up job »

Symptôme trompeur : le conteneur de job est bien démarré mais ne consomme **rien**, tandis que le conteneur `runner` est collé à sa limite CPU. Il n'y a ni erreur ni redémarrage — le job avance, dix fois trop lentement.

Le coupable est presque toujours le **throttling CFS** du conteneur `runner`, souvent aggravé par un `GOMEMLIMIT` trop serré : le tas Go colle au seuil, le ramasse-miettes tourne en continu et mange le quota CPU à la place du travail utile.

Confirmer en lisant le cgroup du conteneur — c'est la seule mesure qui tranche, `kubectl top` ne montre pas le throttling :

```bash
CID=$(kubectl -n forgejo-actions get pod forgejo-runner-0 \
        -o jsonpath='{range .status.containerStatuses[*]}{.name}{" "}{.containerID}{"\n"}{end}' \
      | awk '/^runner /{print $2}' | sed 's#.*/##')
CG=$(sudo find /sys/fs/cgroup/kubepods.slice -maxdepth 4 -type d -name "*${CID}*" | head -1)

grep -E 'nr_periods|nr_throttled|throttled_usec|usage_usec' "$CG/cpu.stat"
grep -E '^anon ' "$CG/memory.stat"
```

Lecture :

- `nr_throttled` proche de `nr_periods` → le conteneur passe l'essentiel de son temps **gelé**.
- `throttled_usec` du même ordre que `usage_usec` → il perd autant de temps qu'il en obtient. Relever `limits.cpu`.
- `anon` proche de la valeur de `GOMEMLIMIT` → le GC tourne en boucle. Relever **les deux** : `limits.memory` et `GOMEMLIMIT` avec lui.

Relevé réel ayant motivé le dimensionnement actuel, avec `cpu: 500m` / `memory: 512Mi` / `GOMEMLIMIT=400MiB` :

```
nr_periods 1217   nr_throttled 824        # 68 % des périodes throttlées
usage_usec 42.1 s throttled_usec 44.2 s   # plus de temps gelé qu'exécuté
anon 379 Mio                              # tas collé au GOMEMLIMIT
```

Conséquence sur un job réel : **2 min 38 s** passées sur une seule étape de préparation (le clone d'`actions/cache` côté runner), pendant que le conteneur de job affichait 0 % de CPU.

Les valeurs livrées aujourd'hui — `cpu: 2`, `memory: 1Gi`, `GOMEMLIMIT=768MiB` — corrigent le cas. Après modification de `k3s/runner/20-runner-statefulset.yaml`, **relever d'abord le `ResourceQuota`** sinon le nouveau pod est refusé (cf. [§11](#cas-1--plus-de-jobs-en-parallèle-même-type-de-runner)).

> Si le throttling n'est **pas** confirmé, chercher ailleurs : un job lent sur `Set up job` peut aussi venir d'un `docker pull` d'image volumineuse, ou d'une action référencée hébergée sur un dépôt lent à cloner.

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

Le plus souvent : `ResourceQuota` dépassé (voir [§11](#11-ajouter-des-runners)) ou volume non provisionné.

### Des runners « offline » s'accumulent dans l'interface

Symptôme d'un `/data` non persistant. Le StatefulSet livré ici l'évite ; les entrées mortes se suppriment dans *Site Administration → Actions → Runners*.

---

## 14. Désinstallation

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

## 15. Améliorations possibles

- **Cache des actions** (`cache.enabled: true` dans `k3s/runner/10-runner-config.yaml`) : accélère nettement les workflows qui réinstallent des dépendances. Demande de vérifier que les conteneurs de job joignent bien le serveur de cache du runner — laissé désactivé par défaut pour éviter un mode de panne silencieux.
- **Analyse SonarQube** : fait — le serveur tourne dans ce même cluster, voir **[SETUP-SONARQUBE.md](SETUP-SONARQUBE.md)**.
