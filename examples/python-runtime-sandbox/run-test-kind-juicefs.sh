#!/bin/bash
# Copyright 2025 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# 一键部署：Kind 集群 + agent-sandbox + MinIO + Redis + JuiceFS CSI + 两个共享 JuiceFS 的 Sandbox Pod
# Ref: https://juicefs.com/docs/zh/community/juicefs_on_k3s

set -e

export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agent-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUICEFS_DIR="${SCRIPT_DIR}/juicefs-shared"
CSI_DRIVER_URL="https://raw.githubusercontent.com/juicedata/juicefs-csi-driver/master/deploy/k8s.yaml"

# 跟随开发指南构建并部署 agent-sandbox 到 kind
cd "${SCRIPT_DIR}/../.."
make build
make deploy-kind
cd "${SCRIPT_DIR}"

echo "Building sandbox-runtime image..."
docker build -t sandbox-runtime .

echo "Loading sandbox-runtime image into kind cluster..."
kind load docker-image sandbox-runtime:latest --name "${KIND_CLUSTER_NAME}"

echo "=== Deploying JuiceFS infra (namespace, MinIO, Redis) ==="
kubectl apply -f "${JUICEFS_DIR}/namespace.yaml"
kubectl apply -f "${JUICEFS_DIR}/minio.yaml"
kubectl apply -f "${JUICEFS_DIR}/redis.yaml"

echo "Waiting for MinIO and Redis to be ready (MinIO sidecar creates bucket dynamically)..."
kubectl wait --for=condition=available deployment/minio -n juicefs-infra --timeout=120s
kubectl wait --for=condition=available deployment/redis -n juicefs-infra --timeout=120s
# 给 sidecar 一点时间完成 bucket 创建（MinIO ready 后 sidecar 才连得上）
sleep 5

echo "=== Deploying JuiceFS CSI Driver ==="
kubectl apply -f "${CSI_DRIVER_URL}"

echo "Waiting for JuiceFS CSI controller and node to be ready..."
kubectl wait --for=condition=ready pod -l app=juicefs-csi-controller -n kube-system --timeout=120s
kubectl wait --for=condition=ready pod -l app=juicefs-csi-node -n kube-system --timeout=120s

echo "=== Deploying JuiceFS Secret, StorageClass, PVC ==="
kubectl apply -f "${JUICEFS_DIR}/juicefs-secret.yaml"
kubectl apply -f "${JUICEFS_DIR}/juicefs-storageclass.yaml"
kubectl apply -f "${JUICEFS_DIR}/juicefs-pvc.yaml"

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/juicefs-shared-pvc -n default --timeout=120s

echo "Waiting for agent-sandbox-controller to be ready..."
kubectl wait --for=condition=available deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=120s

echo "=== Deploying two Sandbox pods with shared JuiceFS PVC ==="
kubectl apply -f "${JUICEFS_DIR}/sandbox-shared-1.yaml"
kubectl apply -f "${JUICEFS_DIR}/sandbox-shared-2.yaml"

echo "Waiting for sandbox pods to be created..."
for i in $(seq 1 60); do
  count=$(kubectl get pod -n default -l sandbox=python-juicefs-shared --no-headers 2>/dev/null | wc -l)
  if [ "${count}" -ge 2 ]; then
    break
  fi
  echo "  waiting for 2 pods... (${count}/2) (${i}/60)"
  sleep 2
done
count=$(kubectl get pod -n default -l sandbox=python-juicefs-shared --no-headers 2>/dev/null | wc -l)
if [ "${count}" -lt 2 ]; then
  echo "ERROR: expected 2 sandbox pods, got ${count}"
  exit 1
fi

echo "Waiting for sandbox pods to be ready..."
kubectl wait --for=condition=ready pod -l sandbox=python-juicefs-shared -n default --timeout=120s

echo "=== Verifying shared JuiceFS: write from pod1, read from pod2 ==="
POD1=$(kubectl get pods -n default -l sandbox-instance=1 -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl get pods -n default -l sandbox-instance=2 -o jsonpath='{.items[0].metadata.name}')
if [ -z "${POD1}" ] || [ -z "${POD2}" ]; then
  echo "ERROR: could not get pod names (POD1=${POD1:-<empty>}, POD2=${POD2:-<empty>})"
  exit 1
fi
SHARED_TEST_FILE="/shared/juicefs-shared-test-$$.txt"
SHARED_CONTENT="Hello from pod1 at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

kubectl exec -n default "${POD1}" -- sh -c "printf '%s' \"${SHARED_CONTENT}\" > ${SHARED_TEST_FILE}"
echo "Pod1 (${POD1}) wrote: ${SHARED_CONTENT}"
READ_BACK=$(kubectl exec -n default "${POD2}" -- cat "${SHARED_TEST_FILE}")
READ_BACK_TRIMMED="${READ_BACK%$'\n'}"
echo "Pod2 (${POD2}) read back: ${READ_BACK}"
if [ "${READ_BACK_TRIMMED}" = "${SHARED_CONTENT}" ]; then
  echo "Shared JuiceFS verification OK: both pods see the same file."
else
  echo "Shared JuiceFS verification FAILED: expected '${SHARED_CONTENT}', got '${READ_BACK_TRIMMED}'"
  exit 1
fi
kubectl exec -n default "${POD1}" -- rm -f "${SHARED_TEST_FILE}"

# Cleanup function: delete Sandbox CRs first (pods go away), then PVC, then infra
cleanup() {
  echo "Cleaning up JuiceFS shared sandboxes and infra..."
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-shared-1.yaml"
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-shared-2.yaml"
  # Wait for pods to terminate so PVC can be released
  kubectl wait --for=delete pod -l sandbox=python-juicefs-shared -n default --timeout=60s 2>/dev/null || true
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/juicefs-pvc.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${JUICEFS_DIR}/juicefs-storageclass.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${JUICEFS_DIR}/juicefs-secret.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${JUICEFS_DIR}/minio.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${JUICEFS_DIR}/redis.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${JUICEFS_DIR}/namespace.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${CSI_DRIVER_URL}" 2>/dev/null || true
  kubectl delete --timeout=10s --ignore-not-found deployment agent-sandbox-controller -n agent-sandbox-system
  kubectl delete --timeout=10s --ignore-not-found crd sandboxes.agents.x-k8s.io
  echo "Deleting kind cluster..."
  cd "${SCRIPT_DIR}/../.."
  make delete-kind
  cd "${SCRIPT_DIR}"
}
# 取消注释下一行则脚本结束时自动清理
# trap cleanup EXIT

echo "Done. Two pods (${POD1}, ${POD2}) share JuiceFS PVC at /shared."
echo "To cleanup later: uncomment 'trap cleanup EXIT' in this script and re-run, or run cleanup steps manually."
