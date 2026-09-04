#!/usr/bin/env bash
# Applique les manifestes k3s de la CI en substituant les variables de .env.
#
# Les manifestes versionnés ne contiennent aucune valeur propre à un
# environnement : seulement ${FORGEJO_DOMAIN} et ${NODE_LAN_IP}, remplacés ici.
# Le token d'enregistrement, lui, n'est JAMAIS dans un fichier — il vit dans un
# Secret Kubernetes créé à la main (voir SETUP-K3S.md).
set -euo pipefail

cd "$(dirname "$0")/.."
NS=forgejo-actions

[ -f .env ] || { echo "✗ .env manquant — 'cp .env-template .env' puis renseigne-le." >&2; exit 1; }
set -a; . ./.env; set +a

: "${FORGEJO_DOMAIN:?absent de .env}"
: "${NODE_LAN_IP:?absent de .env}"

command -v kubectl  >/dev/null || { echo "✗ kubectl introuvable — k3s est-il installé ?" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "✗ envsubst introuvable — sudo apt-get install -y gettext-base" >&2; exit 1; }

# Liste explicite : envsubst ne doit toucher QUE ces deux variables, surtout pas
# les $VAR des scripts shell embarqués dans les manifestes.
VARS='${FORGEJO_DOMAIN} ${NODE_LAN_IP}'

echo "→ Namespace et garde-fous"
kubectl apply -f k3s/00-namespace.yaml

if ! kubectl -n "$NS" get secret forgejo-runner-token >/dev/null 2>&1; then
  cat >&2 <<EOF

✗ Secret 'forgejo-runner-token' absent du namespace $NS.
  Génère un token puis crée le secret :

    docker exec -u git forgejo forgejo actions generate-runner-token
    kubectl -n $NS create secret generic forgejo-runner-token --from-literal=token='<TOKEN>'

EOF
  exit 1
fi

# Tout manifeste numéroté à partir de 10 (00-namespace.yaml est déjà appliqué
# plus haut). Ajouter un runner = déposer un k3s/30-*.yaml, rien à modifier ici.
for f in $(ls k3s/[1-9]*.yaml 2>/dev/null | sort); do
  echo "→ $f"
  envsubst "$VARS" < "$f" | kubectl apply -f -
done

echo
echo "✓ Appliqué. Suivi :"
echo "    kubectl -n $NS get pods -w"
echo "    kubectl -n $NS logs forgejo-runner-0 -c runner -f"
