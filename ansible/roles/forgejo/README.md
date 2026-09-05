# Rôle `forgejo`

Déploie la pile de la forge : Forgejo, sa base PostgreSQL, son compte d'administration et sa jail fail2ban. Le rôle s'arrête là où l'API commence — dépôts, organisations et secrets relèvent d'OpenTofu.

## Où le rôle écrit, et pourquoi pas ailleurs

`forgejo_base_dir` vaut **`/srv/forgejo`**, et non `/opt/forgejo` où l'installation manuelle de piserv cohabite aujourd'hui avec le dépôt git. La raison est concrète : y écrire depuis Ansible écraserait un `docker-compose.yml` versionné, et rendrait le dépôt sale à chaque convergence. Reprendre l'installation existante est une étape à part entière (feuille de route, étape 7), pas un effet de bord de ce rôle.

## Aucun `app.ini` n'est écrit par Ansible

Tentant, et faux. L'entrypoint de l'image réécrit `app.ini` à chaque démarrage à partir des variables `FORGEJO__section__CLE`. Un `app.ini` posé par Ansible serait modifié dans la seconde qui suit : deux sources de vérité pour le même fichier, un diff permanent, et l'idempotence perdue. Toute la configuration passe donc par l'environnement du conteneur.

## Les quatre clés applicatives

```yaml
forgejo_secret_key: ""        # vide = Forgejo la produit lui-même
forgejo_internal_token: ""
forgejo_oauth2_jwt_secret: ""
forgejo_lfs_jwt_secret: ""
```

**Vides par défaut, et c'est le bon réglage pour une installation neuve.** Forgejo les produit à son premier démarrage et les conserve dans `data/gitea/conf/app.ini`, à l'intérieur du volume — donc dans la sauvegarde.

Le seul cas qui justifie de les renseigner est la restauration d'une base existante sur un volume vide. Elles doivent alors valoir **exactement** ce que contenait l'`app.ini` d'origine :

| Clé | Ce que sa perte coûte |
|---|---|
| `SECRET_KEY` | irréparable — chiffre en base les secrets TOTP et les identifiants des dépôts miroirs |
| `INTERNAL_TOKEN` | sessions internes invalidées, se régénère |
| `JWT_SECRET` | jetons OAuth2 invalidés, se réémettent |
| `LFS_JWT_SECRET` | jetons LFS invalidés, se réémettent |

> Une sauvegarde qui contient la base mais pas le `SECRET_KEY` ne restaure pas une forge : elle restaure une forge amputée, et rien ne le signale avant qu'on cherche à s'authentifier en TOTP.

## L'assistant web est verrouillé

`forgejo_install_lock` vaut `true`. Tout ce que l'assistant demanderait — base, domaine, ports — est déjà décidé ici, et le laisser ouvert sur une instance joignable depuis Internet revient à offrir la configuration de la forge au premier arrivant.

Conséquence directe : sans compte d'administration, l'instance démarre inaccessible. Le rôle en crée un quand `forgejo_admin_username` et `forgejo_admin_password` sont fournis, et refuse de s'exécuter si l'un manque sans l'autre.

> Le mot de passe transite par la ligne de commande de `forgejo admin user create` — la seule interface qu'offre l'outil. Il est visible dans `ps` le temps de l'exécution, sur un hôte où seul root peut agir. `no_log` l'empêche au moins d'entrer dans les journaux d'Ansible.

## La jail fail2ban

Le rôle possède `filter.d/forgejo.conf` et `jail.d/10-forgejo.conf`. C'est ce qui permettra de retirer le `local.conf` écrit à la main, aujourd'hui signalé par le rôle `common`.

La jail ne vaut que si l'adresse journalisée est celle du client et non celle de nginx. C'est le cas sans réglage supplémentaire : le vhost transmet `X-Forwarded-For`, et Forgejo fait confiance par défaut aux mandataires de `127.0.0.0/8`. **Si nginx déménageait hors de l'hôte**, il faudrait ajouter son adresse à `REVERSE_PROXY_TRUSTED_PROXIES` — sans quoi la jail bannirait le mandataire, c'est-à-dire tout le monde d'un coup.

Se vérifie sans attendre une attaque :

```bash
fail2ban-regex /srv/forgejo/data/gitea/log/gitea.log /etc/fail2ban/filter.d/forgejo.conf
fail2ban-client status forgejo
```

La CI va plus loin : elle émet une authentification refusée à travers nginx et **exige** que la jail l'ait comptée. Une jail « active » qui compte zéro n'est pas une protection — c'est précisément le défaut trouvé sur la jail `sshd`.

## Points de vigilance

- **`pull: missing`, pas `always`.** Les images sont épinglées dans `group_vars/all/main.yml` : récupérer à chaque passage ne changerait rien et ferait dépendre chaque convergence de la disponibilité du registre.
- **Le port applicatif est en loopback strict.** Le seul chemin d'entrée est le vhost nginx, qui porte le TLS, la limitation de débit et le filtrage. Publier 3000 sur une interface joignable contournerait tout cela d'un coup.
- **`.env` est en 0600 root.** Le `docker-compose.yml`, lisible par tous, ne contient que des références `${...}`.
