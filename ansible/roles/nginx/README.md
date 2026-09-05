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

- **`validate: nginx -t`** sur les fichiers de contexte http : une configuration invalide n'atteint jamais le disque.
- **Validation globale en fin de rôle** : les templates pris isolément ne voient pas les conflits entre vhosts, comme deux sites sur la même paire adresse:port.
- **Rechargement, pas redémarrage** : les connexions en cours ne sont pas coupées.

## Points de vigilance

- **`listen` sur une IP LAN plutôt que `0.0.0.0`** rend l'exposition accidentelle impossible, même si la box redirigeait le port par erreur. En contrepartie, `localhost` ne joint pas le service — il faut viser l'IP.
- **`http2 on;` n'existe qu'à partir de nginx 1.25.** Le template utilise `listen … ssl http2`, valable sur toutes les versions.
- **Le certificat est partagé** entre les sites qui portent le même nom d'hôte. Un client qui joint un service par son IP verra donc un avertissement de nom : c'est attendu, la connexion reste chiffrée.
