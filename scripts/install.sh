#!/usr/bin/env bash
# Installe l'environnement du cours CI/CD M2 : un cluster kind, Argo CD et Argo Rollouts.
# Prérequis : Docker démarré (Docker Desktop sur Mac/Windows).
# Windows : à lancer dans WSL2 (Ubuntu), avec l'intégration WSL de Docker Desktop activée.
# Usage : ./scripts/install.sh      (relançable sans risque)
set -euo pipefail

KIND_VERSION="v0.33.0"
ARGOCD_VERSION="v3.5.3"
ROLLOUTS_VERSION="v1.10.0"
CLUSTER="cicd"
IMAGE_REPO="ghcr.io/9m7fjfpv9k-cyber/taskflow"
LAB_IMAGES="${IMAGE_REPO}:1.0.0 ${IMAGE_REPO}:1.1.0 ${IMAGE_REPO}:2.0.0 ${IMAGE_REPO}:2.1.0 ${IMAGE_REPO}:2.2.0 curlimages/curl:latest grafana/k6:latest"

BIN_DIR="${HOME}/.local/bin"
mkdir -p "${BIN_DIR}"
export PATH="${BIN_DIR}:${PATH}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64 | amd64) ARCH="amd64" ;;
  arm64 | aarch64) ARCH="arm64" ;;
  *) fail "Architecture non prise en charge : $(uname -m)" ;;
esac
[ "${OS}" = "darwin" ] || [ "${OS}" = "linux" ] || fail "Lancez ce script sur macOS, Linux ou WSL2."

step "Vérification de Docker"
docker info >/dev/null 2>&1 || fail "Docker ne répond pas. Démarrez Docker Desktop, puis relancez le script."

step "Outils en ligne de commande (dans ${BIN_DIR})"
if ! command -v kubectl >/dev/null 2>&1; then
  K8S_STABLE="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo "${BIN_DIR}/kubectl" "https://dl.k8s.io/release/${K8S_STABLE}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "${BIN_DIR}/kubectl"
fi
if ! kind version 2>/dev/null | grep -q "${KIND_VERSION}"; then
  curl -fsSLo "${BIN_DIR}/kind" "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${OS}-${ARCH}"
  chmod +x "${BIN_DIR}/kind"
fi
if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
  curl -fsSLo "${BIN_DIR}/kubectl-argo-rollouts" \
    "https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/kubectl-argo-rollouts-${OS}-${ARCH}"
  chmod +x "${BIN_DIR}/kubectl-argo-rollouts"
fi
echo "kubectl : $(kubectl version --client 2>/dev/null | head -1)"
echo "kind    : $(kind version)"

step "Cluster kind « ${CLUSTER} »"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "Le cluster existe déjà, on le réutilise."
else
  kind create cluster --name "${CLUSTER}" --wait 180s
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

step "Argo CD ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
# Argo CD relit Git toutes les 60 s au lieu de 180 s : plus confortable en cours.
kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"60s"}}' >/dev/null

step "Argo Rollouts ${ROLLOUTS_VERSION}"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Server-side apply : les CRD Rollouts dépassent 256 Ko une fois l'annotation
# last-applied-configuration ajoutée par un apply client-side.
kubectl apply -n argo-rollouts --server-side --force-conflicts \
  -f "https://github.com/argoproj/argo-rollouts/releases/download/${ROLLOUTS_VERSION}/install.yaml" >/dev/null

step "Attente du démarrage (quelques minutes la première fois)"
kubectl -n argocd rollout restart statefulset/argocd-application-controller >/dev/null
kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=600s

step "Téléchargement des images des labs dans le cluster (évite de saturer le Wi-Fi demain)"
for image in ${LAB_IMAGES}; do
  if docker exec "${CLUSTER}-control-plane" crictl pull "${image}" >/dev/null 2>&1; then
    echo "  ok      ${image}"
  else
    echo "  ÉCHEC   ${image} (pas bloquant : elle sera téléchargée en cours)"
  fi
done

ARGOCD_PASSWORD="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

step "Installation terminée"
cat <<INFO
  Cluster      : kind-${CLUSTER}
  Argo CD      : ./scripts/argocd-ui.sh, puis https://localhost:8080
                 utilisateur admin, mot de passe ${ARGOCD_PASSWORD}
  Rollouts     : kubectl argo rollouts version

  Si une commande est introuvable dans un nouveau terminal, ajoutez cette ligne
  à votre ~/.zshrc ou ~/.bashrc :
    export PATH="\$HOME/.local/bin:\$PATH"
INFO
