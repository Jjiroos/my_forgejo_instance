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

**Et une contrainte matérielle :** SonarQube ne s'endort pas. Ses trois JVM (web, Compute Engine, Elasticsearch) gardent leur tas. Mesuré ici **au repos, sans aucune analyse : 2,0 Gio**. Ce n'est pas un service qu'on laisse tourner « au cas où » sur une petite machine : il est donc **en veille par défaut**, réveillé par la CI et rendormi après 30 min sans analyse — voir [§8](#8-budget-mémoire).

L'architecture retenue :

```
   navigateur          https        nginx (hôte)      http
   du poste admin ─────────────► :9443 ─────────────────────┐
                                 TLS + UFW + allow/deny     │
                                                            ├──► pod sonarqube ──► pod postgres
   conteneur         http  hostPort :9000                   │
   de job CI ──────────────────► lié à l'IP LAN ────────────┘
                                 NetworkPolicy
```

Deux chemins, deux filtres, et c'est délibéré : le navigateur passe par **TLS**, la CI attaque le port interne en direct. Le port 9000 n'est joignable ni depuis le LAN ni depuis Internet.

SonarQube n'est **pas** exposé publiquement : ni 9000 ni 9443 ne sont redirigés par la box, et les deux écoutes sont liées à la seule IP LAN du nœud — même le loopback de la machine ne les atteint pas.

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

Les manifestes laissent SonarQube **en veille** (`replicas: 0`, cf. [§8](#8-budget-mémoire)). Le premier démarrage se fait donc à la main — l'horodatage évite que la veille ne l'éteigne avant 30 min :

```bash
kubectl -n sonarqube patch configmap sonar-activity --type=merge \
  -p "{\"data\":{\"lastActivity\":\"$(date +%s)\"}}"
kubectl -n sonarqube scale statefulset sonarqube-db sonarqube --replicas=1
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
| `k3s/sonarqube/00-namespace.yaml` | namespace, `ResourceQuota` 3 Gio / 3,1 CPU, `LimitRange` |
| `k3s/sonarqube/10-postgres.yaml` | PostgreSQL 16 dédié + PVC 5 Gio |
| `k3s/sonarqube/20-sonarqube.yaml` | SonarQube + PVC data (10 Gio) et extensions (2 Gio) |
| `k3s/sonarqube/30-networkpolicy.yaml` | qui a le droit de joindre l'IHM et la base |
| `k3s/sonarqube/40-veille.yaml` | mise en veille : horodatage, droits de réveil, `CronJob` d'arrêt |

Trois décisions qui méritent une explication :

- **PostgreSQL dédié, pas de mutualisation avec la base de Forgejo.** SonarQube sollicite fortement la sienne pendant une analyse. Faire dépendre la disponibilité de la forge d'un service secondaire serait un mauvais échange pour ~130 Mio économisés.
- **Les trois JVM sont bornées explicitement** (`SONAR_WEB_JAVAOPTS`, `SONAR_CE_JAVAOPTS`, `SONAR_SEARCH_JAVAOPTS` à `-Xmx512m`). Sans ces bornes, chaque JVM se dimensionne sur la RAM **de la machine** et non sur la limite du conteneur : le pod se fait tuer au démarrage. Elasticsearch impose en plus `Xms = Xmx`.
- **`fsGroup: 1000`** : l'image tourne en uid 1000 alors que les volumes `local-path` sont créés `root:root`. Sans ça, SonarQube ne peut pas écrire dans `/opt/sonarqube/data`.

---

## 4. Première connexion et token CI

Le compte par défaut est `admin` / `admin`. **À changer immédiatement.**

> Les commandes de cette section s'exécutent **depuis le serveur**, sur le port 9000 en clair. C'est le seul moment où c'est nécessaire : une fois le vhost TLS en place ([§7](#7-utiliser-et-paramétrer-le-serveur)), l'accès navigateur passe par HTTPS et le port 9000 n'est plus joignable depuis le réseau.

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
| `SONAR_KUBE_TOKEN` | le jeton de réveil, cf. [§8](#réveil-depuis-la-ci) |
| `SONAR_KUBE_CA` | l'autorité du cluster, cf. [§8](#réveil-depuis-la-ci) |

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

Copier ensuite [`examples/workflows/sonar-analysis.yml`](examples/workflows/sonar-analysis.yml) dans `.forgejo/workflows/` du dépôt et [`examples/sonar/sonar-wake.sh`](examples/sonar/sonar-wake.sh) à sa racine, et pousser.

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

### Accéder à l'interface

L'accès nominal se fait **en HTTPS**, via un vhost nginx qui termine le TLS et relaie vers le port 9000 :

```
https://<SOUS_DOMAINE>.duckdns.org:9443
```

Le port 9000 en clair n'est **plus joignable depuis le réseau** : il ne sert plus qu'aux conteneurs de job de la CI et au serveur lui-même.

Le certificat ne couvrant qu'un seul nom, le poste client doit résoudre ce nom vers l'IP LAN — le port 9443 n'étant pas redirigé par la box, passer par l'IP publique ne mène nulle part. Une ligne dans le fichier `hosts` du poste suffit :

```
<IP_LAN>    <SOUS_DOMAINE>.duckdns.org
```

> Sous Windows : `C:\Windows\System32\drivers\etc\hosts`, à éditer en administrateur. Sous Linux/macOS : `/etc/hosts`.

À défaut, `https://<IP_LAN>:9443` fonctionne aussi — la connexion est chiffrée, mais le navigateur avertit que le nom du certificat ne correspond pas.

### Le vhost TLS

Il réutilise le certificat de la forge : même nom d'hôte, donc **aucune automatisation supplémentaire** — le cron acme.sh existant le renouvelle et recharge nginx.

`/etc/nginx/sites-available/sonarqube` :

```nginx
server {
    listen <IP_LAN>:9443 ssl http2;      # port délibérément NON redirigé par la box
    server_name <SOUS_DOMAINE>.duckdns.org;

    ssl_certificate     /etc/nginx/ssl/forgejo.crt;
    ssl_certificate_key /etc/nginx/ssl/forgejo.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    access_log /var/log/nginx/sonarqube-access.log;
    error_log  /var/log/nginx/sonarqube-error.log;

    allow <IP_POSTE_ADMIN>;              # poste d'administration
    allow <IP_LAN>;                      # le serveur lui-même
    deny  all;

    server_tokens off;
    client_max_body_size 50m;            # rapports d'analyse volumineux
    proxy_read_timeout   600s;
    proxy_send_timeout   600s;

    proxy_http_version 1.1;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options          DENY                always;
    add_header X-Content-Type-Options   nosniff             always;
    add_header Referrer-Policy          strict-origin-when-cross-origin always;

    location / {
        proxy_pass http://<IP_LAN>:9000;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/sonarqube /etc/nginx/sites-enabled/sonarqube
sudo nginx -t && sudo systemctl reload nginx
```

> `http2 on;` est une directive de nginx ≥ 1.25. Sur les versions antérieures, c'est `listen … ssl http2` — la forme utilisée ci-dessus, valable partout.

Déclarer enfin l'URL publique côté SonarQube, sinon les liens qu'il génère pointent sur son adresse interne :

```bash
curl -u admin:<MDP> -X POST "http://<IP_LAN>:9000/api/settings/set" \
  --data-urlencode "key=sonar.core.serverBaseURL" \
  --data-urlencode "value=https://<SOUS_DOMAINE>.duckdns.org:9443"
```

### Ce qui protège le service — deux filtres, deux mécanismes

C'est le point le moins intuitif de cette installation : **le pare-feu ne s'applique pas au même endroit selon le chemin emprunté.**

| Chemin | Nature | Filtre efficace |
|---|---|---|
| `:9443` → nginx | socket sur l'hôte → chaîne `INPUT` | **UFW** |
| `:9000` → `hostPort` k3s | DNAT vers le pod → chaîne `FORWARD` | **NetworkPolicy** |

> ⚠️ **UFW ne filtre pas un `hostPort` k3s.** Le trafic est DNAT vers le pod, donc il traverse `FORWARD`, où k3s insère ses règles **avant** celles d'UFW :
>
> ```
> FORWARD → KUBE-ROUTER-FORWARD → (pod sans NetworkPolicy → marque 0x20000)
>         → -m mark --mark 0x20000 -j ACCEPT     ← accepté ici
>         → ... ufw-before-forward ...            ← jamais atteint
> ```
>
> Une règle UFW sur le port 9000 n'a **aucun effet**. Vérifier soi-même avant de conclure :
>
> ```bash
> sudo iptables -S FORWARD | head
> sudo iptables -S KUBE-POD-FW-<hash>      # le hash vient de KUBE-ROUTER-FORWARD
> ```

Le dispositif complet :

| Garde-fou | Effet |
|---|---|
| Aucune redirection de 9443 ni 9000 sur la box | inaccessible depuis Internet |
| `listen <IP_LAN>:9443` et `hostIP: <IP_LAN>` | jamais exposé au-delà du réseau local |
| Règle UFW sur 9443 | seul le poste d'administration atteint nginx |
| `allow` / `deny all` dans le vhost | second verrou, indépendant d'UFW |
| `NetworkPolicy sonarqube-ingress` | 9000 réservé aux conteneurs de job |
| `NetworkPolicy sonarqube-db-ingress` | PostgreSQL réservé au pod SonarQube |
| `sonar.forceAuthentication=true` (défaut) | API en `401` sans identifiants |
| TLS sur 9443 | le mot de passe ne circule plus en clair |

```bash
sudo ufw allow from <IP_POSTE_ADMIN> to any port 9443 proto tcp comment 'SonarQube TLS'
```

Les deux verrous du chemin HTTPS sont volontairement redondants : une règle UFW et une directive nginx ne tombent pas en panne pour les mêmes raisons.

#### La NetworkPolicy

`k3s/sonarqube/30-networkpolicy.yaml` réserve le port 9000 aux conteneurs de job :

```yaml
  ingress:
    - from:
        - ipBlock: { cidr: 10.42.0.0/16 }    # conteneurs de job (CI)
      ports:
        - { protocol: TCP, port: 9000 }
```

Deux points qui ne sont pas évidents :

- **Le CIDR des pods est indispensable.** Les conteneurs de job joignent SonarQube par l'IP LAN du nœud, mais au moment où la politique est évaluée la source est encore l'IP du pod runner : la traduction *hairpin* n'a lieu qu'en `POSTROUTING`, après le filtrage. Sans cette entrée, **toute analyse échoue**.
- **Impossible de se verrouiller dehors.** kube-router place un `--src-type LOCAL -j ACCEPT` en amont de la chaîne de politique. Le serveur garde l'accès, les sondes du kubelet passent, et c'est aussi ce qui permet à nginx — qui émet depuis le nœud — de relayer sans figurer dans la politique.

Vérifier que le filtrage mord vraiment — une politique qui n'est pas testée ne prouve rien :

```bash
# depuis un conteneur de job, en HTTPS : doit être refusé par nginx (403)
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- \
  docker run --rm --network bridge curlimages/curl:8.11.1 \
  -sk -o /dev/null -w '%{http_code}\n' https://<IP_LAN>:9443/api/system/status

# le même conteneur, en direct sur 9000 : doit passer (200), sinon la CI casse
kubectl -n forgejo-actions exec forgejo-runner-0 -c dind -- \
  docker run --rm --network bridge curlimages/curl:8.11.1 \
  -s -o /dev/null -w '%{http_code}\n' http://<IP_LAN>:9000/api/system/status

# retirer temporairement la seule entrée autorisée, re-tester : doit échouer
kubectl -n sonarqube patch networkpolicy sonarqube-ingress --type json \
  -p '[{"op":"remove","path":"/spec/ingress/0/from/0"}]'
set -a && . ./.env && set +a && ./k3s/apply.sh sonarqube     # restaurer
```

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

SonarQube, lui, n'a pas besoin de ce geste : il se met en veille tout seul.

### Mise en veille

Le tableau ci-dessus décrit SonarQube **allumé**. Il ne l'est que lorsqu'on s'en sert : au repos, ses ~1,7 Gio reviennent à la machine. Les volumes, l'historique d'analyse et la configuration sont conservés.

| Phase | Qui | Quoi |
|---|---|---|
| Réveil | le job CI, via `sonar-wake.sh` | horodate `sonar-activity`, passe base et serveur à 1 réplique, attend `UP` |
| Fin d'analyse | le job CI, `sonar-wake.sh --touch` | horodate à nouveau : le délai part de là |
| Veille | le `CronJob` `sonar-idle`, toutes les 10 min | si 30 min sans activité **et** Compute Engine sans tâche : serveur à 0, puis base à 0 |

Le réveil prend **environ 60 s** sur ce Pi 5 ; c'est le surcoût de la première analyse après une période calme. Deux analyses rapprochées ne le paient qu'une fois.

**Pourquoi un délai et pas un arrêt en fin de job** : deux pipelines concurrentes, la première éteindrait SonarQube sous la seconde. Le délai absorbe ce cas et laisse le temps de lire le rapport.

**Limite connue** : une analyse dont la phase locale (côté scanner) dure plus de 30 min peut voir SonarQube s'éteindre avant l'envoi de son rapport. Pour un tel projet, relever `IDLE_SECONDS` dans `40-veille.yaml`.

**Consulter les rapports** : copier [`examples/workflows/sonar-wake.yml`](examples/workflows/sonar-wake.yml) dans un dépôt au choix (avec `sonar-wake.sh`), puis *Actions → Allumer SonarQube → Run workflow*. Chaque lancement relance les 30 min.

#### Réveil depuis la CI

Le job parle à l'API k3s (`https://<IP_LAN>:6443`, déduite de `SONAR_HOST_URL`) avec le jeton du ServiceAccount `sonar-waker`. Ses droits se limitent à changer le nombre de répliques des deux StatefulSets et à horodater `sonar-activity` : ni lecture de secret, ni modification de gabarit de pod.

Relever les deux valeurs à placer en secrets Forgejo (§5) :

```bash
kubectl -n sonarqube get secret sonar-waker-token -o jsonpath='{.data.token}'  | base64 -d   # SONAR_KUBE_TOKEN
kubectl -n sonarqube get secret sonar-waker-token -o jsonpath='{.data.ca\.crt}' | base64 -d   # SONAR_KUBE_CA
```

#### Jeton administrateur de la veille (recommandé)

Pour savoir si le Compute Engine traite encore un rapport, la veille interroge `/api/ce/activity_status`, qui exige *Administer System*. Générer un jeton **utilisateur** depuis le compte administrateur (*Mon compte → Sécurité*), puis :

```bash
kubectl -n sonarqube create secret generic sonarqube-idle-token --from-literal=token='<JETON>'
```

Sans lui, la veille se fie à l'horodatage seul et l'écrit dans ses logs (`kubectl -n sonarqube logs job/<dernier sonar-idle-…>`).

#### Forcer à la main

```bash
kubectl -n sonarqube scale statefulset sonarqube --replicas=0      # endormir
kubectl -n sonarqube scale statefulset sonarqube-db --replicas=0
kubectl -n sonarqube create job veille-maintenant --from=cronjob/sonar-idle   # passer la veille tout de suite
```

⚠️ Réappliquer les manifestes (`./k3s/apply.sh sonarqube`) remet les répliques à 0 : un SonarQube allumé s'éteint.

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

### Plus d'accès à l'IHM depuis le poste d'administration

Prendre les couches dans l'ordre, de la plus externe à la plus interne.

```bash
# 1. nginx écoute-t-il ? (depuis le serveur)
ss -lnt | grep 9443

# 2. le vhost répond-il localement ?
curl -sk -o /dev/null -w '%{http_code}\n' https://<IP_LAN>:9443/api/system/status

# 3. UFW laisse-t-il passer le poste ?
sudo ufw status | grep 9443

# 4. nginx a-t-il refusé la requête ? (403 = allow/deny du vhost)
sudo tail -5 /var/log/nginx/sonarqube-error.log
```

Causes fréquentes, par ordre de probabilité :

- **L'IP du poste a changé.** C'est le point fragile du dispositif : elle est écrite en dur dans la règle UFW *et* dans le vhost. Un bail DHCP statique sur la box évite le problème définitivement. Après changement, mettre à jour `ADMIN_WORKSTATION_IP` dans `.env`, la directive `allow` du vhost, et la règle UFW.
- **Le nom ne résout pas vers l'IP LAN.** Le port 9443 n'étant pas redirigé, passer par l'IP publique ne mène nulle part. Vérifier l'entrée `hosts` du poste. En dépannage immédiat, `https://<IP_LAN>:9443` fonctionne malgré l'avertissement de certificat.
- **Le certificat a expiré.** `sudo openssl x509 -in /etc/nginx/ssl/forgejo.crt -noout -dates`. Le renouvellement est porté par le cron acme.sh de la forge — si la forge est en HTTPS valide, SonarQube l'est aussi.

En dernier recours, le serveur lui-même conserve toujours l'accès direct : `curl http://<IP_LAN>:9000/…` depuis une session SSH. kube-router garantit ce chemin, il ne peut pas être coupé par une politique.

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
