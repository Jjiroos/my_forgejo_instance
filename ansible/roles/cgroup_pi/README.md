# Rôle `cgroup_pi`

Active le contrôleur cgroup `memory` sur Raspberry Pi. **Ne s'applique qu'au profil `raspberry_pi`** : un arm64 générique partage l'architecture du Pi, pas son amorçage, et le contrôleur y est déjà actif.

## Le piège

kubelet a besoin du contrôleur `memory` pour appliquer la moindre limite RAM. Sans lui, k3s démarre normalement et **tous les `ResourceQuota` deviennent décoratifs** — sur une machine où trois services se partagent 8 Gio, c'est la garantie qui disparaît, pas un détail de configuration.

Or le firmware du Pi injecte `cgroup_disable=memory` dans la ligne de commande du noyau, et **ce paramètre n'apparaît nulle part dans `cmdline.txt`**. On peut relire le fichier dix fois sans rien y voir d'anormal. Le seul juge est :

```bash
cat /sys/fs/cgroup/cgroup.controllers
# cpuset cpu io pids          ← pas de "memory"
# cpuset cpu io memory pids   ← correct
```

Les paramètres ajoutés en fin de ligne passent après ceux du firmware et le neutralisent.

## Une seule ligne, sans retour final

`cmdline.txt` doit rester sur **une seule ligne**. Le firmware ne lit que la première : un `\n` de trop et tout ce qui suit disparaît en silence, y compris `root=`. C'est pourquoi le rôle écrit un `content` sans saut de ligne plutôt que d'utiliser `lineinfile`, et contrôle ensuite que `wc -l` renvoie bien `0`. Une sauvegarde horodatée est déposée avant toute écriture.

## Le rôle ne redémarre pas

`cgroup_pi_reboot` vaut `false`. Le paramètre ne prend effet qu'au prochain amorçage, mais décider du moment où un serveur redémarre n'appartient pas à un playbook. Le rôle écrit, signale ce qui reste à faire, et s'arrête là.

Le rôle `k3s`, lui, **refuse de s'installer** si le contrôleur est absent : mieux vaut un playbook qui s'arrête avec un message clair qu'un cluster dont les quotas ne servent à rien.

## Ce que la CI ne peut pas prouver

Rien de ce rôle. Un runner GitHub n'est pas un Pi : le profil ne correspond pas, le rôle est ignoré, et `cmdline.txt` n'existe pas. Seule la carte réelle en fera foi — c'est la première des trois limites listées dans [`IAC.md §9`](../../../IAC.md).
