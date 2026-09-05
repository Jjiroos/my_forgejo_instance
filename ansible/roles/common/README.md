# Rôle `common`

Amène une machine nue à l'état minimal dont tous les autres rôles dépendent : paquets de base, réglages noyau, pare-feu, fail2ban.

## Principe : additif, jamais autoritaire

Le rôle **n'exécute aucun `ufw reset`** et ne supprime aucune règle. La cible peut héberger des services hors périmètre — un serveur de jeu, d'autres sites — dont les règles ne lui appartiennent pas. Il ajoute ce qu'il connaît et laisse le reste intact.

Conséquence à connaître : un `ufw status` sur un hôte existant montrera des règles absentes de ce rôle. C'est voulu, ce n'est pas une dérive.

## Découpage de fail2ban

| Fichier | Propriétaire |
|---|---|
| `jail.d/00-defaults.conf` | ce rôle — `[DEFAULT]` et `[sshd]` |
| `jail.d/10-<service>.conf` | le rôle qui déploie le service |

Un hôte configuré à la main avant l'IaC a souvent un `jail.d/local.conf` mêlant les deux. Le rôle le **signale sans le supprimer** : il porte encore des jails que personne ne revendique.

Cette cohabitation est **inerte, pas transitoirement tolérée** : `jail.d/` est fusionné par ordre alphabétique, et les valeurs sont identiques. Vérifié sur l'hôte — `bantime=600`, `maxretry=5`, jails `sshd` et `forgejo` actives, avec ou sans `00-defaults.conf`. Il n'y a donc rien à retirer à la main ; `local.conf` disparaîtra quand le rôle `forgejo` reprendra sa jail.

### Le piège du `journalmatch`

Une jail `sshd` peut être *active*, correctement configurée en apparence, et ne jamais rien bannir. Deux conditions doivent être réunies, pas une :

1. **`backend = systemd`** — Debian 12 n'écrit plus `/var/log/auth.log`. Sans cela, la jail lit un fichier qui n'existe pas.
2. **`journalmatch` corrigé** — le filtre fourni par fail2ban cherche `_SYSTEMD_UNIT=sshd.service`, or Debian et Ubuntu nomment l'unité **`ssh.service`**. Le match ne correspond jamais.

Mesuré sur piserv, avant correction : une authentification refusée (`Invalid user … from 127.0.0.1`, bien présente dans le journal sous `_SYSTEMD_UNIT=ssh.service`) laissait `Total failed: 0`. Le rôle pose donc `journalmatch` explicitement, réglable par `common_fail2ban_sshd_journalmatch` pour les distributions qui, elles, nomment bien l'unité `sshd.service`.

Contrôle en une commande :

```bash
sudo fail2ban-client get sshd journalmatch     # doit citer ssh.service
sudo fail2ban-client status sshd               # Total failed doit bouger après un échec réel
```

## Points de vigilance

- **`backend = systemd` sur la jail sshd.** Debian 12 n'écrit plus `/var/log/auth.log`. Sans ce réglage, la jail démarre, ne lit rien et ne bannit jamais personne — silencieusement.
- **`ignoreip` couvre le LAN.** Se bannir soi-même depuis le réseau local est le premier accident classique.
- **`routed: deny` ne protège pas les pods.** k3s insère ses règles avant celles d'UFW dans `FORWARD` : le filtrage du trafic vers un `hostPort` passe par une `NetworkPolicy`, pas par UFW. Voir `SETUP-SONARQUBE.md §7`.
- **`vm.max_map_count`** est écrit dans `/etc/sysctl.d/99-sonarqube.conf`, le fichier que la documentation décrit déjà, pour converger dessus plutôt que d'en créer un doublon.
