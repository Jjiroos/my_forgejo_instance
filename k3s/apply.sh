#!/usr/bin/env bash
# Applique les manifestes k3s d'un composant en substituant les variables de .env.
#
#   ./k3s/apply.sh            → runner (défaut)
#   ./k3s/apply.sh sonarqube
#
# Les manifestes versionnés ne contiennent aucune valeur propre à un
# environnement : seulement ${FORGEJO_DOMAIN} et ${NODE_LAN_IP}, remplacés ici.
# Les secrets (token de runner, mot de passe PostgreSQL) n'existent que dans des
# Secrets Kubernetes créés à la main — jamais dans un fichier.
set -euo pipefail

cd "$(dirname "$0")/.."
COMPONENT="${1:-runner}"
DIR="k3s/$COMPONENT"

[ -d "$DIR" ] || {
  echo "✗ composant inconnu : '$COMPONENT'" >&2
  echo "  disponibles : $(find k3s -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)" >&2
  exit 1
}

[ -f .env ] || { echo "✗ .env manquant — 'cp .env-template .env' puis renseigne-le." >&2; exit 1; }
set -a; . ./.env; set +a

: "${FORGEJO_DOMAIN:?absent de .env}"
: "${NODE_LAN_IP:?absent de .env}"

command -v kubectl  >/dev/null || { echo "✗ kubectl introuvable — k3s est-il installé ?" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "✗ envsubst introuvable — sudo apt-get install -y gettext-base" >&2; exit 1; }

# Liste explicite : envsubst ne doit toucher QUE ces deux variables, surtout pas
# les $VAR des scripts shell embarqués dans les manifestes.
VARS='${FORGEJO_DOMAIN} ${NODE_LAN_IP}'

# Le premier manifeste (00-*) crée le namespace : il doit passer avant la
# vérification des secrets, qui vivent dedans.
NS_FILE="$DIR/00-namespace.yaml"
[ -f "$NS_FILE" ] || { echo "✗ $NS_FILE manquant" >&2; exit 1; }
echo "→ $NS_FILE"
envsubst "$VARS" < "$NS_FILE" | kubectl apply -f -

NS=$(grep -m1 -A2 '^kind: Namespace' "$NS_FILE" | grep -m1 '  name:' | awk '{print $2}')

# Secrets attendus par composant, créés hors dépôt (cf. la documentation).
case "$COMPONENT" in
  runner)    NEEDED="forgejo-runner-token" ; HINT="docker exec -u git forgejo forgejo actions generate-runner-token
    kubectl -n $NS create secret generic forgejo-runner-token --from-literal=token='<TOKEN>'" ;;
  sonarqube) NEEDED="sonarqube-db"          ; HINT="kubectl -n $NS create secret generic sonarqube-db --from-literal=password=\"\$(openssl rand -base64 24)\"" ;;
  *)         NEEDED="" ;;
esac

for sec in $NEEDED; do
  kubectl -n "$NS" get secret "$sec" >/dev/null 2>&1 || {
    printf '\n✗ Secret « %s » absent du namespace %s. Le créer :\n\n    %s\n\n' "$sec" "$NS" "$HINT" >&2
    exit 1
  }
done

for f in $(find "$DIR" -maxdepth 1 -name '[1-9]*.yaml' | sort); do
  echo "→ $f"
  envsubst "$VARS" < "$f" | kubectl apply -f -
done

echo
echo "✓ Appliqué ($COMPONENT). Suivi :"
echo "    kubectl -n $NS get pods -w"
