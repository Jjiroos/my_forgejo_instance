# Industrialisation — Ansible + OpenTofu

Ce document décrit comment la pile documentée dans [SETUP.md](SETUP.md), [SETUP-K3S.md](SETUP-K3S.md) et [SETUP-SONARQUBE.md](SETUP-SONARQUBE.md) devient reproductible : une machine nue, deux commandes, la même infrastructure à l'arrivée.

**Le cas d'usage qui commande tout, c'est la reprise après panne.** Si le serveur meurt demain, ce dépôt doit suffire à reconstruire la mécanique — pas à restaurer les données, qui relèvent des sauvegardes, et pas à retrouver les secrets, qui n'y figurent pas.

Les trois guides restent la **référence explicative** — ils disent *pourquoi* chaque réglage existe. Le code, lui, dit *comment* l'appliquer. Les deux se lisent ensemble.

## Sommaire

1. [Périmètre](#1-périmètre)
2. [Décisions structurantes](#2-décisions-structurantes)
3. [La frontière Ansible / OpenTofu](#3-la-frontière-ansible--opentofu)
4. [Le problème d'amorçage](#4-le-problème-damorçage)
5. [Structure du dépôt](#5-structure-du-dépôt)
6. [Secrets — hors du dépôt, sans exception](#6-secrets--hors-du-dépôt-sans-exception)
7. [Multi-architecture](#7-multi-architecture)
8. [Reprise de l'existant](#8-reprise-de-lexistant)
9. [Éprouver le code : la CI GitHub](#9-éprouver-le-code--la-ci-github)
10. [Limites connues](#10-limites-connues)
11. [Feuille de route](#11-feuille-de-route)

---

## 1. Périmètre

Ce dépôt industrialise **la mécanique de déploiement**, pas les charges qui tournent dessus.

| Dans le périmètre | Hors périmètre |
|---|---|
| nginx : le **mécanisme** vhost + TLS + ouverture UFW | les sites effectivement déployés |
| Certificats acme.sh en DNS-01 DuckDNS | serveur de jeu et autres services applicatifs |
| Forgejo + PostgreSQL | données : dépôts git, bases, historiques d'analyse |
| k3s et les runners Forgejo Actions | secrets et jetons |
| SonarQube et son PostgreSQL dédié | configuration shell personnelle (`.bashrc`, dotfiles) |
| UFW, fail2ban, sysctl, prérequis noyau | |

La distinction sur nginx est la plus importante, et c'est elle qui fait la valeur de l'ensemble : le rôle ne connaîtra **aucun site en particulier**. Il prend une liste de sites en donnée — nom, domaine, port d'écoute, service en amont, restrictions d'accès — et produit pour chacun le certificat, le vhost et la règle de pare-feu.

Forgejo et SonarQube y entrent comme deux entrées de cette liste, et servent d'exemples complets. Déployer un site supplémentaire devient une ligne de configuration, pas une procédure.

Les données ne sont jamais du ressort de l'IaC : elles relèvent des sauvegardes. Reconstruire l'infrastructure et restaurer les données sont deux opérations distinctes, dans cet ordre.

## 2. Décisions structurantes

| Décision | Choix | Raison |
|---|---|---|
| Couche hôte | **Ansible** | Paquets, sysctl, UFW, nginx, certificats n'ont pas d'API déclarative |
| Couche applicative | **OpenTofu** | k3s, Forgejo et SonarQube en ont une, et de vrais providers existent |
| Cibles | **arm64 + amd64** | Une VM jetable permet de valider un déploiement complet sans toucher au serveur |
| Existant | **importé** | Le serveur en production devient géré par le code, sans rien recréer |
| Secrets | **SOPS + age, hors dépôt** | Chiffrés au repos et sauvegardables ailleurs — mais jamais versionnés, même chiffrés |

## 3. La frontière Ansible / OpenTofu

La règle est simple : **OpenTofu ne gère que ce qui a une API et un état interrogeable.** Tout le reste est à Ansible.

### Ce qu'OpenTofu pilote

| Domaine | Provider | Ressources utiles |
|---|---|---|
| Cluster k3s | `hashicorp/kubernetes` | namespaces, quotas, NetworkPolicies, StatefulSets, PVC |
| Forgejo | `svalabs/forgejo` | utilisateurs, organisations, dépôts, équipes, protections de branche, webhooks, **secrets et variables Actions**, jetons personnels |
| SonarQube | `jdamata/sonarqube` | projets, quality gates et leurs conditions, profils, permissions, **jetons** |
| Secrets | `carlpett/sops` | déchiffrement natif, valeurs marquées sensibles d'office |

Bénéfice concret : le piège « Secrets vs Variables » qui a coûté une matinée devient impossible. Le type est écrit dans le code, il n'y a plus d'onglet où se tromper.

### Ce qu'Ansible pilote

| Domaine | Pourquoi pas OpenTofu |
|---|---|
| Paquets apt, installation de k3s, Docker, nginx | aucun état déclaratif à interroger |
| `/boot/firmware/cmdline.txt` (`cgroup_enable=memory`) | fichier système **et redémarrage requis** |
| `/etc/sysctl.d/99-sonarqube.conf`, règles UFW, fail2ban | idem |
| Vhosts nginx et leur `reload` | idem |
| acme.sh, émission DuckDNS en DNS-01, cron de renouvellement | idem |
| Pile docker-compose de la forge | le provider `docker` existe, mais remplacerait un compose qui fonctionne par du code moins lisible |

> On *peut* forcer tout ceci en `null_resource` + `remote-exec`. On perdrait alors l'idempotence et la détection de dérive — les deux seules raisons de faire de l'IaC.

## 4. Le problème d'amorçage

Les providers `kubernetes`, `forgejo` et `sonarqube` doivent joindre leur cible **dès la phase `plan`**, pas seulement à l'`apply`. Un `tofu apply` unique depuis une machine nue est donc structurellement impossible : on ne peut pas planifier contre un service qui n'existe pas encore.

D'où un découpage en étages, chacun avec son propre état :

```
  ansible/site.yml          machine nue → hôte prêt
        │                   (k3s répond, Forgejo répond, TLS en place)
        ▼
  tofu/00-cluster           ressources k3s → runner + SonarQube démarrent
        │
        ├──► tofu/10-forgejo      utilisateurs, dépôts, protections
        │            │
        ▼            ▼
  tofu/20-analysis    projets et quality gates SonarQube,
                      + les secrets Actions qui câblent les deux
```

`00-cluster` et `10-forgejo` sont indépendants et peuvent être appliqués dans n'importe quel ordre. `20-analysis` dépend des deux : il produit le jeton d'analyse SonarQube **et** le secret Forgejo qui le consomme. Les deux providers cohabitent dans cet étage précisément pour que le jeton ne transite ni par un humain ni par un fichier intermédiaire.

## 5. Structure du dépôt

```
.sops.yaml.example            gabarit des règles de chiffrement
.sops.yaml                    ← généré, ignoré par git
secrets/
  piserv.example.yaml         gabarit sans valeur
  piserv.sops.yaml            ← chiffré, local, ignoré par git
ansible/
  ansible.cfg
  site.yml                    point d'entrée
  requirements.yml            collections requises
  inventory/hosts.example.yml gabarit
  inventory/hosts.yml         ← ignoré par git
  inventory/ci.yml            cible de la CI : le runner lui-même
  group_vars/all/main.yml     versions épinglées, ports, prérequis noyau
  group_vars/all/sites.yml    services publiés (références seules)
  group_vars/ci/main.yml      surcharges de CI, valeurs fictives
  roles/                      common, acme, nginx, docker, forgejo
tofu/
  00-cluster/                 ressources k3s
  10-forgejo/                 configuration de la forge
  20-analysis/                SonarQube + câblage
.github/workflows/
  iac-lint.yml                analyse statique, sans effet de bord
  iac-converge.yml            déploiement réel sur runner jetable
```

Le motif est constant : **un gabarit versionné, un fichier réel ignoré**. Il s'applique déjà à `.env-template` et se généralise ici.

## 6. Secrets — hors du dépôt, sans exception

**Aucun secret n'entre dans ce dépôt, chiffré ou non.** C'est une règle, pas une préférence : un texte chiffré publié est un texte chiffré publié pour toujours, et la solidité d'un algorithme aujourd'hui n'engage personne sur la durée de vie d'un dépôt public.

SOPS reste utilisé, mais pour ce qu'il sait faire d'utile ici : protéger les fichiers **au repos sur la machine** et les rendre sauvegardables ailleurs sans exposer les valeurs. Il ne les autorise pas à entrer dans git.

| Fichier | Versionné | Contenu |
|---|---|---|
| `secrets/piserv.example.yaml` | ✅ | la forme attendue, aucune valeur |
| `.sops.yaml.example` | ✅ | les règles de chiffrement, destinataire à renseigner |
| `secrets/piserv.sops.yaml` | ❌ | les vraies valeurs, chiffrées, locales |
| `.sops.yaml` | ❌ | le destinataire réel |
| `~/.config/sops/age/keys.txt` | ❌ | la clé privée, hors dépôt par nature |

La protection ne repose pas sur la vigilance : `.gitignore` refuse `secrets/*` sauf les gabarits, et tout fichier `*.sops.yaml` où qu'il soit. Vérifié en tentant d'ajouter un faux secret — refusé.

### Mise en place sur une machine neuve

```bash
age-keygen -o ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt
cp .sops.yaml.example .sops.yaml
sed -i "s|<DESTINATAIRE_AGE>|$(grep '^# public key:' ~/.config/sops/age/keys.txt | cut -d' ' -f4)|" .sops.yaml
cp secrets/piserv.example.yaml secrets/piserv.sops.yaml
sops -e -i secrets/piserv.sops.yaml   # puis `sops secrets/piserv.sops.yaml` pour remplir
```

Ansible et OpenTofu lisent ensuite ce fichier sans jamais écrire de valeur en clair sur le disque : `data "sops_file"` côté OpenTofu, `community.sops` côté Ansible.

### Conséquence sur la reprise après panne

Le dépôt ne suffit pas à lui seul. Il faut, depuis une sauvegarde hors machine :

1. **La clé age privée.** Sans elle, un `secrets/piserv.sops.yaml` sauvegardé est définitivement illisible.
2. **Le fichier de secrets chiffré**, ou de quoi régénérer chaque valeur.

Certaines valeurs se régénèrent sans douleur (mot de passe PostgreSQL sur une base neuve, jetons d'API, jeton d'enregistrement du runner). D'autres non — le jeton DuckDNS est lié au compte, et le `SECRET_KEY` de Forgejo doit correspondre à la base restaurée, sinon les données chiffrées de la forge deviennent inexploitables.

> Une sauvegarde qui contient la base mais pas la clé age ni le `SECRET_KEY` ne permet pas une reprise. C'est le point à vérifier **avant** d'en avoir besoin.

## 7. Multi-architecture

La VM amd64 n'est pas un confort : c'est le **test de non-régression** du code. Un rôle qui passe sur les deux cibles ne contient plus de valeur propre au Pi.

| Point | Traitement |
|---|---|
| `cgroup_enable=memory` dans `cmdline.txt` | spécifique Raspberry Pi — conditionné sur `host_profile` |
| Images de conteneurs | toutes multi-arch : `sonarqube:community`, `postgres:16-alpine`, `docker:27-dind`, `node:22-bookworm`, runner Forgejo |
| sonar-scanner | le zip est par architecture (`linux-aarch64` / `linux-x64`) — à dériver des faits |
| Providers OpenTofu | les quatre ont un binaire `linux_arm64`, vérifié |
| `.terraform.lock.hcl` | verrouillé pour `linux_amd64` **et** `linux_arm64`, versionné ainsi. Un verrou mono-plateforme fait échouer `tofu init` sur l'autre — c'est ce que la CI amd64 aurait rencontré au premier essai. Après ajout d'un provider : `tofu providers lock -platform=linux_amd64 -platform=linux_arm64` |

## 8. Reprise de l'existant

Le serveur en production ne sera pas recréé. Chaque ressource déjà en place est rattachée à l'état par un bloc `import`, revu dans un `plan` avant tout `apply`.

Le critère de réussite est net : **un `tofu plan` qui ne propose aucun changement.** Tant qu'il en propose, le code ne décrit pas fidèlement la réalité.

Les données ne sont jamais concernées : dépôts git, base PostgreSQL, volumes k3s et historique d'analyse restent intouchés.

## 9. Éprouver le code : la CI GitHub

Deux workflows tournent sur le dépôt public. Ils ne touchent aucune machine réelle : la cible est le runner GitHub lui-même, une VM neuve détruite à la fin du job.

| Workflow | Ce qu'il prouve | Durée |
|---|---|---|
| `iac-lint.yml` | le code est bien formé, aucun secret n'est versionné, les trois étages OpenTofu sont valides | ~2 min |
| `iac-converge.yml` | le playbook amène une machine nue à l'état attendu, **deux fois de suite sans rien changer la seconde**, sur amd64 et sur arm64 | ~5 min |

### Pourquoi un runner jetable est la bonne cible

Ce dépôt promet une chose : reproduire l'infrastructure après une panne, sur une machine neuve. Un runner hébergé **est** cette machine neuve. Le tester revient à jouer le scénario de reprise à chaque commit, ce qu'aucune vérification sur le serveur en production ne peut faire — un serveur déjà configuré converge trivialement.

### L'idempotence est le vrai test

Le second passage doit rapporter `changed=0`. Un playbook qui « marche » mais rejoue les mêmes modifications à chaque exécution n'est pas de l'infrastructure comme code : c'est un script shell déguisé, qu'on n'ose plus relancer sur une machine en service. Le workflow échoue si le compteur n'est pas à zéro.

### Ce que la convergence contrôle après coup

`changed=0` prouve la convergence, pas le résultat. Le workflow regarde ensuite la machine elle-même : `vm.max_map_count`, le certificat et ses extensions, `nginx -t`, les ports en écoute, les règles UFW, les jails de fail2ban, l'état des conteneurs et la santé applicative de la forge.

**Les deux vhosts doivent répondre différemment, et c'est là qu'est le contrôle.** Celui de la forge répond `200` sur `/api/healthz` : terminaison TLS, relais et application réellement démarrée derrière, prouvés d'un coup. Celui de SonarQube répond `502`, parce que ce playbook ne déploie pas SonarQube — un 502 n'est pas un échec ici, c'est la preuve que le vhost relaie vers un amont absent. Obtenir autre chose signifierait qu'il ne fait pas ce qu'il annonce.

Trois contrôles portent sur ce qui échoue silencieusement quand on ne le regarde pas :

- **La forge est-elle accessible sans l'assistant web ?** Le job vérifie que le compte d'administration existe, créé en ligne de commande. Une instance verrouillée sans compte est une instance perdue.
- **Le port applicatif est-il vraiment en loopback ?** `3000` doit apparaître lié à `127.0.0.1` et jamais à `0.0.0.0` — sinon tout le filtrage du vhost est contournable.
- **La jail compte-t-elle réellement ?** Le job émet une authentification refusée à travers nginx, puis exige que `fail2ban-client status forgejo` rapporte au moins un échec. Une jail « active » qui compte zéro n'est pas une protection ; c'est exactement le défaut trouvé sur la jail `sshd`, et ce contrôle-là l'aurait attrapé.

Pour que cette dernière mesure soit possible, la CI passe `ignoreself` à `false` et remplace `ignoreip` par un préfixe RFC 5737 : sans cela, toute tentative émise depuis le runner serait exemptée, et une jail muette resterait indiscernable d'une jail qui fonctionne.

Ce contrôle a payé dès sa première exécution, et pas là où on l'attendait : Ubuntu 24.04 impose `backend = systemd` à toutes les jails depuis un fichier de `jail.d/` chargé après les nôtres, si bien que la jail de la forge ignorait son `logpath`. Debian 12 n'a pas ce réglage — le défaut n'existait pas sur la cible réelle. Une CI qui tourne sur une plateforme que le projet ne vise pas reste utile : elle expose les hypothèses qu'on ne savait pas avoir prises.

### Les secrets, et leur absence

Aucun secret n'est nécessaire, et aucun n'est configuré. Le mode `selfsigned` du rôle `acme` existe pour cela : émettre un vrai certificat exigerait le jeton DuckDNS d'un compte personnel, ce qui n'a pas sa place ici. Le mode auto-signé produit les mêmes fichiers aux mêmes chemins — de quoi éprouver le rôle `nginx` de bout en bout.

Le job `secrets` de `iac-lint.yml` transforme la règle du §6 en contrôle exécutable : il refuse la livraison si un chemin interdit est suivi par git, ou si une clé privée age ou PEM apparaît dans le contenu d'un fichier versionné. Un `.gitignore` exprime une intention ; un `git add -f` la contourne. Ce job, non.

### Ce que la CI ne peut pas prouver

- **Le profil `raspberry_pi`.** Un runner arm64 partage l'architecture du Pi, pas son amorçage : `cgroup_enable=memory` dans `cmdline.txt` et le redémarrage qui suit ne se testent que sur une vraie carte.
- **La reprise de l'existant.** Un runner part toujours d'une machine vierge. La convergence sur un hôte déjà configuré à la main — le cas de piserv — reste à éprouver ailleurs.
- **Le chemin Let's Encrypt.** Sans jeton, l'émission DNS-01 n'est pas exercée ; seule la branche auto-signée l'est.

## 10. Limites connues

À traiter explicitement plutôt qu'à découvrir en route.

- **Le jeton d'enregistrement du runner n'est pas exposé** par le provider Forgejo. Il devra être produit par un appel API et injecté dans SOPS — c'est le seul maillon non déclaratif de la chaîne.
- **Deux providers sont communautaires et non signés.** `svalabs/forgejo` (~56 étoiles) et `jdamata/sonarqube` s'installent sans validation GPG. Le `.terraform.lock.hcl` épingle leurs empreintes, ce qui protège des substitutions ultérieures, mais la confiance initiale repose sur le registre.
- **Ansible packagé par Debian 12 est en core 2.14**, sensiblement en retard. À réévaluer via `pipx` si un module récent venait à manquer. Conséquence directe : la CI tourne sur un `ansible-core` plus récent — 2.14 ne s'installe pas sur le Python 3.12 d'Ubuntu 24.04. Le vert en CI ne garantit donc pas le vert sur piserv ; le lint local, lui, s'exécute bien en 2.14.
- **L'état OpenTofu contient les secrets en clair.** Il est exclu du dépôt ; il doit être inclus dans les sauvegardes et traité avec le même soin que la clé age. Un backend distant reste à arbitrer.
- **Le mot de passe administrateur SonarQube ne peut pas être posé à la création** : le provider s'authentifie avec, alors que l'installation démarre sur `admin/admin`. Le changement initial restera à la charge d'Ansible.

## 11. Feuille de route

| Étape | Contenu | État |
|---|---|---|
| 0 | Outillage, chaîne SOPS/age, squelette, validation des providers en arm64 | **fait** |
| 1 | Rôle `common` : paquets, sysctl, UFW, fail2ban | **fait** |
| 2 | Rôles `acme` et `nginx` — **le mécanisme générique de publication d'un site** | **écrit, éprouvé à blanc** |
| 2 bis | CI GitHub : lint, garde anti-secret, convergence réelle sur amd64 et arm64 | **fait** |
| 3 | Rôles `docker` et `forgejo` : pile docker-compose, compte d'administration, jail | **fait** |
| 4 | Rôles `cgroup_pi` et `k3s` | à faire |
| 5 | `tofu/00-cluster` : migration des manifestes de `k3s/` | à faire |
| 6 | `tofu/10-forgejo` et `tofu/20-analysis` — SonarQube devient le second site | à faire |
| 7 | Import du piserv, jusqu'à un `plan` vide | à faire |
| 8 | Validation complète sur la VM amd64 | à faire |

Les étapes 2 et 3 sont le cœur de la valeur : une fois le couple `acme` + `nginx` paramétré par une liste de sites, publier un nouveau service revient à ajouter une entrée. Forgejo puis SonarQube servent à démontrer que le mécanisme tient sur deux cas réels — l'un exposé sur Internet, l'autre restreint au LAN.

### Deux forges, deux chemins

Le rôle `forgejo` écrit dans **`/srv/forgejo`**. L'installation manuelle de piserv vit dans `/opt/forgejo`, qui est aussi le répertoire de travail de ce dépôt git : y faire écrire Ansible écraserait un `docker-compose.yml` versionné et salirait l'arbre à chaque convergence.

Les deux chemins coexisteront donc jusqu'à l'étape 7. La bascule y consistera à arrêter l'ancienne pile, déplacer `data/` et `postgres-data/`, relever les quatre clés applicatives de l'`app.ini` existant vers le fichier de secrets, puis converger. Elle se prépare, elle ne s'improvise pas.

### Reprise de l'existant : ce qu'il reste à débloquer

Les rôles sont éprouvés en `--check` contre le serveur, mais leur première application réelle demande deux gestes manuels. Ils ne sont pas des oublis : ce sont les points où l'IaC prend possession de fichiers écrits à la main.

Le rôle `nginx` est **propriétaire** de `conf.d/00-rate-limit.conf` et le réécrit intégralement. Ce fichier ne doit donc contenir que des zones du périmètre. Une garde vérifie qu'aucune zone du rôle n'est déjà déclarée dans un *autre* fichier de `conf.d/` : nginx refuse un doublon, avec un message sans appel —

```
[emerg] limit_req_zone "forgejo_login" is already bound to key "$binary_remote_addr"
```

Côté fail2ban, **rien à retirer**. `jail.d/` est fusionné par ordre alphabétique et `local.conf`, qui passe après `00-defaults.conf`, redéclare les mêmes valeurs : la cohabitation est inerte. `local.conf` disparaîtra naturellement quand le rôle `forgejo` reprendra sa jail.

Une nuance depuis : `00-defaults.conf` apporte un réglage que `local.conf` n'a pas — `journalmatch` sur `ssh.service`. Comme `local.conf` ne redéfinit pas cette clé, elle survit à la fusion. Appliquer le rôle **changera donc le comportement de l'hôte**, dans le bon sens : la jail `sshd` de piserv, mesurée le 5 septembre 2026, ne compte aucun échec même après une authentification refusée, parce que le filtre fourni par fail2ban cherche `sshd.service` là où Debian nomme l'unité `ssh.service`. Détail dans [`roles/common/README.md`](ansible/roles/common/README.md).

---

## Hors de ce dépôt

La configuration shell personnelle — `.bashrc`, alias, outillage du compte — relève d'un dépôt de dotfiles distinct. Elle n'a pas sa place ici : ce dépôt décrit une **infrastructure reproductible sur n'importe quelle cible**, pas un environnement de travail personnel. Les deux ont des cycles de vie et des publics différents.
