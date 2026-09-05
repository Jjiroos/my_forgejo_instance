# Rôle `nginx`

Publie un service derrière TLS. **Le rôle ne connaît aucun site en particulier** : il consomme la liste `nginx_sites`, et publier un service supplémentaire revient à y ajouter une entrée.

C'est là qu'est la valeur du dépôt : le triptyque *certificat + vhost + règle de pare-feu* est écrit une fois, puis réutilisé.

## Ce qu'une entrée décrit

```yaml
nginx_sites:
  - name: monsite
    domain: exemple.duckdns.org
    listen: { port: 9443, address: "192.168.1.50" }
    cert: forgejo                       # certificat partagé, même nom d'hôte
    upstream: "http://127.0.0.1:8000"
    allow: ["192.168.1.42"]             # non vide ⇒ `deny all` implicite
    ufw: { manage: true, from: "192.168.1.42" }
```

Les valeurs non précisées viennent de `nginx_site_defaults`.

## Deux cas opposés, un seul mécanisme

Les deux services de ce dépôt servent de démonstration et couvrent les extrêmes :

| | Forgejo | SonarQube |
|---|---|---|
| Écoute | `0.0.0.0:8181` | `<IP_LAN>:9443` |
| Exposition | Internet, via redirection de port | LAN strictement |
| Restriction | aucune (authentification applicative) | `allow` + UFW |
| Particularité | limitation de débit sur la connexion | corps de requête réduit |

## Sécurité de l'exécution

- **Ordre d'écriture** : un fichier de `sites-available/` est inerte tant qu'il n'est pas lié dans `sites-enabled/`. Les vhosts sont donc tous écrits avant que le premier ne soit activé.
- **Validation globale, puis retour arrière** : `nginx -t` est lancé une fois la configuration complète en place — c'est le seul moment où les conflits entre vhosts sont visibles, comme deux sites sur la même paire adresse:port. Si elle échoue, un `rescue` retire le fichier de zones et les liens que l'exécution venait de poser, revérifie, et dit dans son message si la machine est repartie sur une configuration valide.
- **Pourquoi pas `validate:` sur le template** : l'option exige un `%s` et lance la commande sur le fichier candidat seul. Ni un fragment de `conf.d/` ni un vhost ne se valident hors contexte — `nginx -t -c <fragment>` le lirait comme un `nginx.conf` complet et échouerait systématiquement.
- **Rechargement, pas redémarrage** : les connexions en cours ne sont pas coupées.
- **Le fichier de zones est sauvegardé avant réécriture** (`backup: true`). Les copies portent un suffixe horodaté qui ne finit pas par `.conf` : nginx ne les inclut pas, et la garde anti-doublon ne les voit pas non plus.

## Points de vigilance

- **`listen` sur une IP LAN plutôt que `0.0.0.0`** rend l'exposition accidentelle impossible, même si la box redirigeait le port par erreur. En contrepartie, `localhost` ne joint pas le service — il faut viser l'IP.
- **`http2 on;` n'existe qu'à partir de nginx 1.25.** Le template utilise `listen … ssl http2`, valable sur toutes les versions.
- **Le certificat est partagé** entre les sites qui portent le même nom d'hôte. Un client qui joint un service par son IP verra donc un avertissement de nom : c'est attendu, la connexion reste chiffrée.
