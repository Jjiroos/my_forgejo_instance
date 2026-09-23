#!/usr/bin/env bash
# Réveille SonarQube, en veille par défaut (k3s/sonarqube/40-veille.yaml).
#
#   sonar-wake.sh           horodate l'activité, démarre base et serveur, attend UP
#   sonar-wake.sh --touch   horodate seulement — en fin d'analyse, pour que le
#                           délai de mise en veille parte de là
#
# À copier à la racine du dépôt analysé. Secrets attendus (cf. SETUP-SONARQUBE.md §8) :
#   SONAR_HOST_URL    http://<IP_LAN>:9000
#   SONAR_KUBE_TOKEN  jeton du ServiceAccount sonar-waker
#   SONAR_KUBE_CA     certificat de l'autorité du cluster, en PEM
set -euo pipefail

: "${SONAR_HOST_URL:?secret absent}"
: "${SONAR_KUBE_TOKEN:?secret absent}"
: "${SONAR_KUBE_CA:?secret absent}"

NS=sonarqube
STARTUP_TIMEOUT=900   # le startupProbe du pod accorde 10 min, plus la base et le tirage d'image
POLL=10

# SonarQube et l'API k3s vivent sur le même nœud : l'hôte de l'un donne l'autre.
host=${SONAR_HOST_URL#*://}
host=${host%%[:/]*}
API="https://${host}:6443"

ca=$(mktemp)
trap 'rm -f "$ca"' EXIT
printf '%s\n' "$SONAR_KUBE_CA" > "$ca"

patch() {
  curl -fsS --cacert "$ca" -X PATCH \
    -H "Authorization: Bearer $SONAR_KUBE_TOKEN" \
    -H 'Content-Type: application/merge-patch+json' \
    -d "$2" "$API/$1" >/dev/null
}

patch "api/v1/namespaces/$NS/configmaps/sonar-activity" \
  "{\"data\":{\"lastActivity\":\"$(date +%s)\"}}"

[ "${1:-}" = --touch ] && exit 0

for sts in sonarqube-db sonarqube; do
  patch "apis/apps/v1/namespaces/$NS/statefulsets/$sts/scale" '{"spec":{"replicas":1}}'
done

echo "Attente de SonarQube…"
for ((t = 0; t < STARTUP_TIMEOUT; t += POLL)); do
  if curl -fsS "$SONAR_HOST_URL/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
    echo "✓ SonarQube prêt (${t}s)"
    exit 0
  fi
  sleep "$POLL"
done
echo "✗ SonarQube n'est pas UP après ${STARTUP_TIMEOUT}s — kubectl -n $NS get pods" >&2
exit 1
