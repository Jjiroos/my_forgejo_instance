# Rôle `docker`

Installe le moteur Docker et le plugin `compose` depuis le dépôt officiel, puis borne les journaux des conteneurs.

## Pourquoi pas le paquet de la distribution

Debian 12 fournit `docker.io`, plusieurs versions majeures en retard, et **sans le plugin `compose` v2**. Toute la pile de ce dépôt est décrite en `docker-compose.yml` et pilotée par `docker compose` : le paquet distribution ne permet pas de la démarrer.

## Journaux bornés, et pourquoi ça compte

```yaml
docker_daemon_options:
  log-driver: json-file
  log-opts: { max-size: "10m", max-file: "3" }
```

Sans rotation, le pilote `json-file` écrit sans limite. Sur une machine dont le stockage se compte en dizaines de gigaoctets, un conteneur bavard remplit la partition en quelques semaines — et un disque plein arrête la forge plus sûrement qu'une panne matérielle. Trente mégaoctets par conteneur est un plafond, pas une cible.

## Le groupe `docker` n'est pas un détail

`docker_users` est **vide par défaut**. Appartenir au groupe `docker` équivaut à un accès root : le démon tourne en root et accepte de monter n'importe quel chemin de l'hôte dans un conteneur. C'est une décision d'inventaire, à prendre en connaissance de cause, pas un confort qu'un rôle accorde d'office.

## Sources apt en double

`docker_purge_foreign_sources` retire les autres fichiers de `sources.list.d/` qui déclarent `download.docker.com`. Sans cela, une machine déjà pourvue de Docker par un autre chemin — les runners GitHub en sont — se retrouve avec le même dépôt déclaré deux fois, et apt le signale à chaque exécution. Le rôle écrit toujours `docker.list`, le nom que la documentation amont utilise : sur une machine installée selon cette documentation, il n'y a rien à retirer.

## Points de vigilance

- **`present`, jamais `latest`.** Une montée de version du moteur redémarre le démon, donc la forge. Elle se décide, elle ne survient pas au détour d'une convergence de routine.
- **Les handlers sont vidés avant la fin du rôle** (`meta: flush_handlers`). Un redémarrage du démon en attente doit avoir eu lieu avant que le rôle `forgejo` ne manipule des conteneurs, pas à la fin du playbook.
