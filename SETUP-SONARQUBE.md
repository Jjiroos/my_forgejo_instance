# SonarQube — serveur d'analyse de code dans k3s

Déploiement d'un **SonarQube Community** sur le cluster k3s monté par [SETUP-K3S.md](SETUP-K3S.md), et branchement de l'analyse sur les workflows Forgejo Actions. Validé sur Raspberry Pi 5 (Debian 12, ARM64) avec SonarQube 26.9.

## Sommaire

1. [Ce qu'il faut savoir avant de commencer](#1-ce-quil-faut-savoir-avant-de-commencer)
2. [Prérequis hôte](#2-prérequis-hôte)
3. [Déployer](#3-déployer)
4. [Première connexion et token CI](#4-première-connexion-et-token-ci)
5. [Brancher un dépôt](#5-brancher-un-dépôt)
6. [Le cas C / C++](#6-le-cas-c--c)
7. [Utiliser et paramétrer le serveur](#7-utiliser-et-paramétrer-le-serveur)
8. [Budget mémoire](#8-budget-mémoire)
9. [Exploitation](#9-exploitation)
10. [Dépannage](#10-dépannage)
11. [Désinstallation](#11-désinstallation)

---

## 1. Ce qu'il faut savoir avant de commencer

**Deux limites d'édition, à connaître avant d'investir de la RAM :**

| Langage | Community (gratuit) |
|---|---|
| Python, Java, JS/TS, C#, Go, Kotlin, PHP, Ruby, Scala, HTML, CSS, XML | ✅ analysé nativement |
| **C, C++** | ❌ analyseur réservé aux éditions payantes — contournement en [§6](#6-le-cas-c--c) |

**Et une contrainte matérielle :** SonarQube ne s'endort pas. Ses trois JVM (web, Compute Engine, Elasticsearch) gardent leur tas. Mesuré ici **au repos, sans aucune analyse : 2,0 Gio**. Ce n'est pas un service qu'on installe « au cas où » sur une petite machine — voir [§8](#8-budget-mémoire).

L'architecture retenue :

```
   navigateur (LAN) ─────────┐
                             ├──► http://<IP_LAN>:9000 ──► pod sonarqube ──► pod postgres
   conteneur de job CI ──────┘         (hostPort lié à l'IP LAN,
                                        jamais 0.0.0.0, jamais Internet)
```

SonarQube n'est **pas** exposé publiquement : rien n'est ajouté au port-forward de la box, et le `hostPort` est lié à la seule IP LAN du nœud — même le loopback de la machine ne l'atteint pas.

---

## 2. Prérequis hôte

Elasticsearch, embarqué dans SonarQube, exige une limite de mappings mémoire bien supérieure au défaut. **C'est la cause n°1 des SonarQube qui refusent de démarrer.**

```bash
echo 'vm.max_map_count=524288' | sudo tee /etc/sysctl.d/99-sonarqube.conf
sudo sysctl --system
sysctl -n vm.max_map_count      # doit afficher 524288
```

Persistant au redémarrage, applicable à chaud — aucun reboot nécessaire.

---

## 3. Déployer

Le mot de passe PostgreSQL est généré et injecté directement dans un Secret : il ne transite par aucun fichier.

```bash
cd /opt/forgejo
kubectl apply -f k3s/sonarqube/00-namespace.yaml
kubectl -n sonarqube create secret generic sonarqube-db \
  --from-literal=password="$(openssl rand -base64 24)"
./k3s/apply.sh sonarqube
```

Suivre le démarrage — compter **3 à 5 minutes** au premier lancement, le temps qu'Elasticsearch construise ses index :

```bash
kubectl -n sonarqube get pods -w
curl -s http://<IP_LAN>:9000/api/system/status      # {"status":"UP"}
```

Tant que le statut est `STARTING`, l'API répond déjà mais l'interface n'est pas utilisable. Ce n'est pas un symptôme.

### Ce que contiennent les manifestes

| Fichier | Contenu |
|---|---|
| `k3s/sonarqube/00-namespace.yaml` | namespace, `ResourceQuota` 3 Gio / 3 CPU, `LimitRange` |
| `k3s/sonarqube/10-postgres.yaml` | PostgreSQL 16 dédié + PVC 5 Gio |
| `k3s/sonarqube/20-sonarqube.yaml` | SonarQube + PVC data (10 Gio) et extensions (2 Gio) |
| `k3s/sonarqube/30-networkpolicy.yaml` | qui a le droit de joindre l'IHM et la base |

Trois décisions qui méritent une explication :

- **PostgreSQL dédié, pas de mutualisation avec la base de Forgejo.** SonarQube sollicite fortement la sienne pendant une analyse. Faire dépendre la disponibilité de la forge d'un service secondaire serait un mauvais échange pour ~130 Mio économisés.
- **Les trois JVM sont bornées explicitement** (`SONAR_WEB_JAVAOPTS`, `SONAR_CE_JAVAOPTS`, `SONAR_SEARCH_JAVAOPTS` à `-Xmx512m`). Sans ces bornes, chaque JVM se dimensionne sur la RAM **de la machine** et non sur la limite du conteneur : le pod se fait tuer au démarrage. Elasticsearch impose en plus `Xms = Xmx`.
- **`fsGroup: 1000`** : l'image tourne en uid 1000 alors que les volumes `local-path` sont créés `root:root`. Sans ça, SonarQube ne peut pas écrire dans `/opt/sonarqube/data`.

---

## 4. Première connexion et token CI

Le compte par défaut est `admin` / `admin`. **À changer immédiatement** : le service est joignable depuis n'importe quel appareil du LAN.

```bash
curl -u admin:admin -X POST "http://<IP_LAN>:9000/api/users/change_password" \
  --data-urlencode "login=admin" \
  --data-urlencode "previousPassword=admin" \
  --data-urlencode "password=<NOUVEAU_MOT_DE_PASSE>"
# 204 = fait
```

> La politique de mot de passe exige au moins un caractère spécial ; sinon la réponse est un `400` explicite.

Vérifier que l'ancien ne passe plus — attention, `/api/authentication/validate` répond **200 même en cas d'échec**, avec `{"valid":false}` dans le corps. Tester plutôt sur un point d'entrée authentifié :

```bash
curl -o /dev/null -w '%{http_code}\n' -u admin:admin "http://<IP_LAN>:9000/api/users/search"   # 401 attendu
```

Générer ensuite le token que la CI utilisera. Un **token d'analyse global** vaut pour tous les projets, y compris ceux qui n'existent pas encore :

```bash
curl -u admin:<MOT_DE_PASSE> -X POST "http://<IP_LAN>:9000/api/user_tokens/generate" \
  --data-urlencode "name=forgejo-ci" \
  --data-urlencode "type=GLOBAL_ANALYSIS_TOKEN"
```

Le token n'est affiché **qu'une seule fois**.

---

## 5. Brancher un dépôt

Dans Forgejo, sur le dépôt à analyser : *Paramètres → Actions → Secrets*, ajouter

| Secret | Valeur |
|---|---|
| `SONAR_HOST_URL` | `http://<IP_LAN>:9000` |
| `SONAR_TOKEN` | le token généré en [§4](#4-première-connexion-et-token-ci) |

> Un secret d'**utilisateur** ou d'**organisation** (*Paramètres du compte → Actions → Secrets*) évite de le répéter sur chaque dépôt — le bon choix dès qu'on a plus d'un projet à analyser.

### ⚠️ Secrets et Variables ne sont pas la même chose

Forgejo sépare en deux objets ce que GitLab réunit dans une seule liste cochable :

| | **Secrets** | **Variables** |
|---|---|---|
| Stockage | **chiffré** au repos, clé dérivée de `SECRET_KEY` | **en clair** |
| Relecture | impossible — *write-only* | affichée et éditable |
| Masquage dans les logs de job | oui | **non** |
| Contexte du workflow | `${{ secrets.NOM }}` | `${{ vars.NOM }}` |

Les deux contextes sont **étanches** : une variable nommée `SONAR_TOKEN` n'alimente pas `${{ secrets.SONAR_TOKEN }}`, le job reçoit une chaîne vide et échoue comme si le secret n'existait pas.

Le piège vient des portées, qui sont asymétriques :

| Portée | Secrets | Variables |
|---|---|---|
| Dépôt | ✅ | ✅ |
| Organisation | ✅ | ✅ |
| Utilisateur | ✅ | ✅ |
| **Instance** (*Site Administration → Actions*) | **❌ n'existe pas** | ✅ |

La page d'administration ne propose donc **que** des Variables : c'est l'endroit le plus naturel où aller, et le seul qui ne puisse pas convenir. Pour un secret valable sur tous ses dépôts, la portée la plus large est le **niveau utilisateur** (`/user/settings/actions/secrets`).

Vérification en une requête — la colonne `data` d'un secret est chiffrée, celle d'une variable ne l'est pas :

```bash
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT name, owner_id, repo_id FROM secret;" \
  -c "SELECT name, owner_id, repo_id FROM action_variable;"
```

L'API le confirme aussi : les secrets n'exposent que `PUT` et `DELETE`, jamais de `GET`.

Copier ensuite [`examples/workflows/sonar-analysis.yml`](examples/workflows/sonar-analysis.yml) dans `.forgejo/workflows/` du dépôt, et pousser.

### L'action officielle fonctionne aussi en arm64

`examples/workflows/sonar-analysis.yml` télécharge le scanner à la main, pour rester lisible et sans dépendance. Mais `SonarSource/sonarqube-scan-action@v4` **marche sur ce cluster** : c'est une action composite qui choisit la bonne architecture toute seule, vérifié ici sur `Linux … aarch64`. Elle gère en plus la mise en cache du CLI.

```yaml
      - uses: SonarSource/sonarqube-scan-action@v4
        env:
          SONAR_TOKEN:    ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ secrets.SONAR_HOST_URL }}
```

À ne pas confondre avec l'**image** `sonarsource/sonar-scanner-cli`, qui n'est publiée qu'en amd64 et ne tourne pas ici.

### Pourquoi l'image de base est Node et pas Java

Le zip `sonar-scanner-cli-<version>-linux-aarch64.zip` **embarque son propre JRE** : aucun Java à installer. En revanche l'analyseur JS/TS/CSS de SonarQube lance `node` pendant l'analyse et **échoue sans lui** :

```
NodeCommandException: Error when running: 'node -v'. Is Node.js available during analysis?
```

D'où `runs-on: docker`, dont le label pointe sur `node:22-bookworm`. Une image Java pure ne suffit pas, même si le scanner est un programme Java.

### Réglages utiles

```
-Dsonar.tests=tests                     # sépare code de test et code de production
-Dsonar.python.version=3.11             # précision de l'analyse Python
-Dsonar.exclusions=**/node_modules/**,**/dist/**
```

`fetch-depth: 0` sur le checkout n'est pas cosmétique : SonarQube date les problèmes à partir de l'historique git. Sans historique complet, tout le code apparaît comme neuf et la Quality Gate « nouveau code » perd tout sens.

---

## 6. Le cas C / C++

Community n'a pas d'analyseur C/C++, mais accepte l'**import de problèmes externes**. On délègue donc le diagnostic à `cppcheck` (packagé en arm64) et on injecte ses résultats.

**Vérifié en conditions réelles :** les fichiers `.c` sont bien indexés par Community même sans analyseur associé, et les problèmes importés apparaissent dans le tableau de bord au même titre que les autres. Test effectué sur un fichier C contenant un dépassement de tampon et une fuite mémoire — les quatre défauts détectés par cppcheck sont remontés.

Ce que le pont **ne** fournit **pas** : couverture de tests, duplication, et hotspots de sécurité sur le C/C++. Ces métriques restent l'apanage de l'analyseur SonarSource des éditions payantes.

Mise en œuvre :

1. Copier [`examples/sonar/cppcheck-to-sonar.py`](examples/sonar/cppcheck-to-sonar.py) à la racine du dépôt.
2. Copier [`examples/workflows/sonar-cpp.yml`](examples/workflows/sonar-cpp.yml) dans `.forgejo/workflows/`.

Le workflow lance cppcheck, convertit son XML au format *generic issue*, puis passe le fichier au scanner via `-Dsonar.externalIssuesReportPaths`. Les règles apparaissent préfixées `external_cppcheck:`.

> Le scanner émet un avertissement `Property 'sonar.externalIssuesReportPaths' is not declared as multi-values` — il est bénin, l'import fonctionne.

---

## 7. Utiliser et paramétrer le serveur

### Accéder à l'interface — et ce qui la protège vraiment

L'interface s'ouvre dans un navigateur depuis n'importe quelle machine du LAN :

```
http://<IP_LAN>:9000
```

**`http://localhost:9000` ne fonctionne pas, même depuis le serveur lui-même.** Le `hostPort` est lié à l'IP LAN précise et non à `0.0.0.0` : c'est ce qui garantit que le service ne peut pas être exposé par erreur, mais il faut donc toujours viser l'IP.

> ⚠️ **UFW ne filtre pas un `hostPort` k3s.** Le trafic est DNAT vers le pod, donc il traverse `FORWARD`, où k3s insère ses règles **avant** celles d'UFW :
>
> ```
> FORWARD → KUBE-ROUTER-FORWARD → (pod sans NetworkPolicy → marque 0x20000)
>         → -m mark --mark 0x20000 -j ACCEPT     ← accepté ici
>         → ... ufw-before-forward ...            ← jamais atteint
> ```
>
> Le port est donc joignable depuis tout le LAN **bien qu'aucune règle UFW ne l'autorise** et que la politique soit `deny (routed)`. Ajouter ou retirer une règle UFW pour ce port n'a aucun effet. Vérifier soi-même avant de conclure :
>
> ```bash
> sudo iptables -S FORWARD | head
> sudo iptables -S KUBE-POD-FW-<hash>      # le hash vient de KUBE-ROUTER-FORWARD
> ```

Ce qui protège réellement le service :

| Garde-fou | Effet |
|---|---|
| `hostIP: <IP_LAN>` dans le manifeste | jamais exposé au-delà du réseau local |
| Aucune redirection de port sur la box | inaccessible depuis Internet |
| `sonar.forceAuthentication=true` (défaut) | API en `401` sans identifiants |
| `NetworkPolicy sonarqube-ingress` | **seul** filtre efficace par adresse source |

#### Restreindre l'accès à certaines machines

UFW étant inopérant ici, le filtrage se fait par `NetworkPolicy` — c'est kube-router qui les applique, et c'est lui qui décide sur ce chemin. `k3s/sonarqube/30-networkpolicy.yaml` n'autorise l'IHM que depuis le poste d'administration déclaré dans `.env` :

```yaml
  ingress:
    - from:
        - ipBlock: { cidr: ${ADMIN_WORKSTATION_IP}/32 }   # poste d'administration
        - ipBlock: { cidr: 10.42.0.0/16 }                 # conteneurs de job (CI)
      ports:
        - { protocol: TCP, port: 9000 }
```

Deux points qui ne sont pas évidents :

- **Le CIDR des pods est indispensable.** Les conteneurs de job joignent SonarQube par l'IP LAN du nœud, mais au moment où la politique est évaluée la source est encore l'IP du pod runner : la traduction *hairpin* n'a lieu qu'en `POSTROUTING`, après le filtrage. Sans cette entrée, **toute analyse échoue**.
- **Impossible de se verrouiller dehors.** kube-router place un `--src-type LOCAL -j ACCEPT` en amont de la chaîne de politique : le serveur lui-même garde l'accès, et les sondes du kubelet continuent de passer.

Une seconde politique restreint PostgreSQL au seul pod SonarQube.

Vérifier que le filtrage mord vraiment — une politique qui n'est pas testée ne prouve rien :

```bash
# 1. retirer temporairement le CIDR des pods
kubectl -n sonarqube patch networkpolicy sonarqube-ingress --type json \
  -p '[{"op":"remove","path":"/spec/ingress/0/from/1"}]'

# 2. depuis un conteneur de job : doit échouer (code curl 7)
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- \
  docker run --rm --network bridge curlimages/curl:8.11.1 \
  -s -m 8 -o /dev/null -w '%{http_code}\n' http://<IP_LAN>:9000/api/system/status

# 3. depuis le serveur : doit toujours répondre 200
curl -s -o /dev/null -w '%{http_code}\n' http://<IP_LAN>:9000/api/system/status

# 4. restaurer
set -a && . ./.env && set +a && ./k3s/apply.sh sonarqube
```

**L'accès est en HTTP, pas HTTPS** : le mot de passe circule en clair sur le réseau local. Le durcissement est un vhost nginx TLS réutilisant le certificat existant, sur un port non redirigé par la box.

### Les deux couches de paramétrage

Ne pas les confondre — une seule des deux est versionnée.

| Couche | Où | Contenu |
|---|---|---|
| **Infra** | `k3s/sonarqube/*.yaml` (versionné) | image, taille des JVM, exposition, sondes, volumes, quotas |
| **Application** | base PostgreSQL, pilotée par l'IHM | profils qualité, Quality Gates, utilisateurs, permissions, tokens |

La couche applicative ne se retrouve **que** dans la sauvegarde de la base (cf. [§9](#9-exploitation)). Après modification d'un manifeste :

```bash
set -a && . ./.env && set +a && ./k3s/apply.sh sonarqube
```

### Premiers réglages conseillés dans l'IHM

- **Définition du « nouveau code »** (*Administration → New Code*). Par défaut `PREVIOUS_VERSION` : sur un dépôt sans versions déclarées, aucune condition n'est évaluable et la Quality Gate reste **verte et vide** à la première analyse. Passer sur *Number of days* la rend immédiatement parlante.
- **Visibilité des projets** (*Administration → Projects → Management*), y compris celle par défaut des nouveaux projets.
- **Un compte non-admin** pour l'usage quotidien (*Administration → Users*).

---

## 8. Budget mémoire

Mesures réelles sur ce serveur, au repos, sans analyse en cours :

| Composant | RAM |
|---|---|
| SonarQube | **2,0 Gio** |
| PostgreSQL SonarQube | 130 Mio |
| Runner CI (dind + act_runner) | 115 Mio |
| Forge, autres services, k3s | ~2,2 Gio |
| **Total** | **~4,4 Gio sur 7,9** |

| Scénario | Tient ? |
|---|---|
| SonarQube + forge + CI au repos | oui, ~3,5 Gio libres |
| SonarQube + une analyse en cours | oui |
| SonarQube + un service lourd de 3 Gio | serré, ~0,5 Gio de marge |
| SonarQube + service lourd + analyse | **non** — swap de 512 Mio, la machine décroche |

Mettre la CI en pause quand la RAM manque, sans rien désinstaller :

```bash
kubectl -n forgejo-actions scale statefulset forgejo-runner --replicas=0   # pause
kubectl -n forgejo-actions scale statefulset forgejo-runner --replicas=1   # reprise
```

Et pour SonarQube lui-même :

```bash
kubectl -n sonarqube scale statefulset sonarqube --replicas=0
```

Les volumes sont conservés, l'historique d'analyse aussi.

---

## 9. Exploitation

| Action | Commande |
|---|---|
| État | `kubectl -n sonarqube get pods` |
| Logs | `kubectl -n sonarqube logs sonarqube-0 -f` |
| Consommation | `kubectl top pod -n sonarqube` |
| Interface k9s | `k9s -n sonarqube` |
| Santé applicative | `curl -s http://<IP_LAN>:9000/api/system/status` |
| Redémarrer | `kubectl -n sonarqube delete pod sonarqube-0` |

**Sauvegarde** : tout l'état utile est dans PostgreSQL. Les volumes `data` et `extensions` se reconstruisent.

```bash
kubectl -n sonarqube exec sonarqube-db-0 -- \
  pg_dump -U sonarqube sonarqube | gzip > sonarqube-$(date +%F).sql.gz
```

**Mises à jour** : une montée de version majeure déclenche une migration de base au premier démarrage. Faire le `pg_dump` **avant**, puis changer le tag de l'image dans `k3s/sonarqube/20-sonarqube.yaml` et réappliquer. Ne jamais sauter plusieurs versions majeures d'un coup.

---

## 10. Dépannage

### Le pod boucle et les logs parlent de `max virtual memory areas`

```
max virtual memory areas vm.max_map_count [65530] is too low, increase to at least [524288]
```

Le prérequis de [§2](#2-prérequis-hôte) n'est pas appliqué. Vérifier `sysctl -n vm.max_map_count` sur **l'hôte**, pas dans le conteneur.

### Le pod est tué au démarrage (`OOMKilled`)

Presque toujours des JVM non bornées : sans `SONAR_*_JAVAOPTS`, elles se dimensionnent sur la RAM de la machine et dépassent la limite du conteneur. Vérifier que les trois variables sont bien présentes.

```bash
sudo dmesg -T | grep -iE 'oom-kill|Memory cgroup' | tail -3
```

`constraint=CONSTRAINT_MEMCG` = limite du conteneur. `CONSTRAINT_NONE` = la machine entière manquait de RAM, c'est le budget global qu'il faut revoir.

### Le job CI échoue sur `node -v`

L'image du job n'a pas Node. Utiliser `runs-on: docker` (cf. [§5](#5-brancher-un-dépôt)).

### `Unsupported Node.JS version detected`

```
ERROR Unsupported Node.JS version detected 20.20.2.
      Please upgrade to the latest Node.JS LTS version.
Caused by: java.lang.IllegalStateException: Error while running Node.js.
```

Piège : l'image du job peut très bien fournir une version récente et le scanner en voir une autre. Une étape `actions/setup-node` place **sa** version en tête du `PATH` et masque celle de l'image.

```yaml
      - uses: actions/setup-node@v4
        with:
          node-version: 20      # ← shadow le Node 22 de l'image
```

Les analyseurs SonarQube suivent le calendrier LTS de Node et laissent tomber les versions en fin de vie. Trois sorties, par ordre de préférence :

1. Aligner `node-version` sur la version de l'image (la voir avec `docker run --rm node:22-bookworm node -v`).
2. Supprimer l'étape `setup-node` si elle ne sert qu'à fournir Node — l'image l'a déjà. À garder en revanche pour son cache npm.
3. En dernier recours, forcer l'interpréteur sans toucher au `PATH` :
   `-Dsonar.nodejs.executable=/usr/local/bin/node`

Le symptôme est reconnaissable : le scan démarre normalement, indexe les fichiers et déroule les *sensors*, puis casse uniquement à l'analyse JS/TS. Les langages déjà traités (Python, CSS…) apparaissent dans le log juste avant l'échec.

### `Failed to get server version` / `no scheme was found`

```
java.lang.IllegalStateException: Failed to get server version
Caused by: java.lang.IllegalArgumentException:
    Expected URL scheme 'http' or 'https' but no scheme was found for /api/s...
```

Le message donne l'impression d'un problème réseau, mais il dit l'inverse : le scanner a construit l'URL `/api/server/version` **sans hôte**. `SONAR_HOST_URL` arrive donc **vide** dans le job.

Par ordre de fréquence :

1. **Créé comme *Variable* au lieu de *Secret*** — de loin la cause la plus courante, parce que la page d'administration ne propose que des Variables. Voir [§5](#-secrets-et-variables-ne-sont-pas-la-même-chose).
2. Secret absent ou mal orthographié.
3. Secret non transmis à l'étape : une `action` ne voit pas les secrets automatiquement, il faut les lui passer via `env:`.

Vérifier que les secrets existent bien :

```bash
# côté base Forgejo — 0 ligne = aucun secret n'a jamais été créé
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT name, repo_id, owner_id FROM secret;"
```

L'échec est immédiat (moins d'une seconde) : si le job tombe tout de suite après le démarrage du scanner, c'est cette piste-là, pas la connectivité.

### Le job CI ne joint pas SonarQube

```bash
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- \
  docker run --rm curlimages/curl:8.11.1 -sS http://<IP_LAN>:9000/api/system/status
```

Si ça échoue : `SONAR_HOST_URL` utilise probablement `localhost` ou le nom public. Les conteneurs de job doivent viser **l'IP LAN du nœud**.

### L'analyse passe mais le projet reste vide

Le rapport est traité de façon asynchrone par le Compute Engine. Suivre la file :

```bash
curl -s -u admin:<MDP> "http://<IP_LAN>:9000/api/ce/component?component=<CLÉ_PROJET>"
```

### Première analyse très lente

Normal : téléchargement des analyseurs, chauffe des JVM, indexation. Les suivantes sont nettement plus rapides.

---

## 11. Désinstallation

```bash
kubectl delete namespace sonarqube          # ⚠️ supprime aussi les volumes et l'historique
sudo rm /etc/sysctl.d/99-sonarqube.conf && sudo sysctl --system
```

Pour ne retirer que le service en gardant les données : `kubectl -n sonarqube scale statefulset sonarqube --replicas=0`.
