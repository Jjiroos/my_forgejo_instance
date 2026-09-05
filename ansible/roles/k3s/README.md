# Rôle `k3s`

Installe un cluster k3s mono-nœud, à la version épinglée dans `group_vars/all/main.yml`.

## Ce qui est désactivé, et ce qui ne l'est pas

| Composant | Décision |
|---|---|
| `traefik` | **désactivé** — nginx fronte déjà tout, aucun Ingress n'est nécessaire |
| `servicelb` | **désactivé** — pas de LoadBalancer sur un nœud unique |
| `metrics-server` | **conservé** — ~65 Mio pour disposer de `kubectl top`, indispensable pour piloter la RAM sur une petite machine |
| `local-path` | **conservé** — fournit les volumes persistants du runner et de SonarQube |

## La garde de version

Le script de `get.k3s.io` est idempotent par accident, pas par contrat : relancé, il retélécharge et réinstalle. Le rôle compare donc `k3s --version` à la version voulue et ne fait rien si elles correspondent — sans quoi chaque convergence redémarrerait le cluster sans raison.

Le script est **téléchargé puis exécuté**, jamais tubé dans un shell. Ce qui s'exécute en root sur la machine doit pouvoir être relu après coup.

## Le pare-feu, dans les deux sens

UFW arrive en `deny (routed)`, ce qui coupe le trafic sortant des pods : un job de CI ne peut alors ni cloner un dépôt ni installer une dépendance. Le rôle ouvre donc les deux réseaux internes.

> ⚠️ **Ne pas en déduire que le trafic vers les pods est filtré par UFW.** k3s insère ses propres règles avant celles d'UFW dans `FORWARD` : un `hostPort` n'est pas filtrable par UFW, et c'est pourquoi la restriction d'accès à SonarQube passe par une `NetworkPolicy` (cf. [`SETUP-SONARQUBE.md §7`](../../../SETUP-SONARQUBE.md)).

La CI éprouve la sortie réseau depuis un **pod réel** — seul endroit où la question se pose vraiment — avec `curlimages/curl`, jamais `busybox` : son `wget` échoue sur certains sites HTTPS pour des raisons de TLS et non de pare-feu, un faux négatif classique.

## Le prérequis qui arrête tout

Le rôle **refuse de s'installer** si le contrôleur cgroup `memory` est absent. k3s démarrerait sans broncher, mais aucune limite mémoire ne serait applicable et tous les `ResourceQuota` seraient décoratifs. Sur Raspberry Pi, c'est le rôle [`cgroup_pi`](../cgroup_pi/README.md) qui règle cela — suivi d'un redémarrage.

## Le kubeconfig

`k3s_kubeconfig_users` est **vide par défaut**. `k3s kubectl` fonctionne toujours en root ; copier les identifiants du cluster dans un répertoire personnel est une décision, pas un confort par défaut. Le répertoire personnel est relevé par `getent`, jamais supposé être `/home/<nom>`.

Sans `KUBECONFIG`, le `kubectl` de k3s lit `/etc/rancher/k3s/k3s.yaml`, illisible par un compte ordinaire : on obtient un `permission denied` là où on attendait une erreur de cluster.
