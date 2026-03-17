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
#
# === 部署后常用运维命令（按需复制执行） ===
#
# 1) MinIO Web 控制台（对象存储桶视图，登录 minioadmin/minioadmin）
#    kubectl port-forward svc/minio -n juicefs-infra 9001:9001
#    浏览器打开 http://localhost:9001
#
# 2) JuiceFS CSI Dashboard（PV/PVC/Mount Pod 状态与日志）
#    kubectl port-forward -n kube-system deployment/juicefs-csi-dashboard 8088:8088
#    浏览器打开 http://localhost:8088
#
# 3) 列出 Mount Pod（同一 PVC 在不同节点各有一个）
#    kubectl get pod -n kube-system -l app.kubernetes.io/name=juicefs-mount -o wide
#
# 4) 进入 Mount Pod 执行 juicefs 命令（必须加 -n kube-system）
#    kubectl exec -n kube-system -it <mount-pod-name> -c jfs-mount -- sh
#    容器内常见挂载点: /jfs 或 /var/lib/juicefs/...
#
# 5) juicefs status（需 metaurl，与 juicefs-secret 中一致）
#    juicefs status redis://redis.juicefs-infra.svc.cluster.local:6379/0
#    可选: juicefs status --session <Sid> <metaurl>
#
# 6) juicefs info（查看文件/目录元数据，参数为挂载点下的路径）
#    juicefs info /jfs
#    juicefs info /jfs/juicefs-default-juicefs-demo-pvc
#    juicefs info -r /jfs/juicefs-default-juicefs-demo-pvc   # 递归目录
#    cd /jfs && juicefs info -i <inode>                       # 按 inode 查
#
# 7) 根目录挂载：不写 subPath；子目录挂载：subPath: user-1/conv-1（相对路径，不要用 subPath: /）

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
# 首次运行 Kind 可能需拉取镜像，适当延长超时
kubectl wait --for=condition=available deployment/minio -n juicefs-infra --timeout=300s
kubectl wait --for=condition=available deployment/redis -n juicefs-infra --timeout=120s
# 给 sidecar 一点时间完成 bucket 创建（MinIO ready 后 sidecar 才连得上）
sleep 10

echo "=== Deploying JuiceFS Secret (before CSI driver so controller can reference it) ==="
kubectl apply -f "${JUICEFS_DIR}/juicefs-secret.yaml"

echo "=== Deploying JuiceFS CSI Driver ==="
kubectl apply -f "${CSI_DRIVER_URL}"

echo "Waiting for JuiceFS CSI controller and node to be ready..."
# 首次运行 Kind 可能需拉取镜像，适当延长超时
kubectl wait --for=condition=ready pod -l app=juicefs-csi-controller -n kube-system --timeout=300s
kubectl wait --for=condition=ready pod -l app=juicefs-csi-node -n kube-system --timeout=300s

echo "=== Deploying JuiceFS StorageClass and PVC ==="
kubectl apply -f "${JUICEFS_DIR}/juicefs-storageclass.yaml"
kubectl apply -f "${JUICEFS_DIR}/juicefs-pvc.yaml"

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/juicefs-demo-pvc -n default --timeout=120s

echo "Waiting for agent-sandbox-controller to be ready..."
kubectl wait --for=condition=available deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=120s

echo "=== Deploying two Sandbox pods with shared JuiceFS PVC ==="
kubectl apply -f "${JUICEFS_DIR}/sandbox-shared-1.yaml"
kubectl apply -f "${JUICEFS_DIR}/sandbox-shared-2.yaml"

echo "Waiting for sandbox pods to be created..."
for i in $(seq 1 60); do
  count=$(kubectl get pod -n default -l sandbox=juicefs-demo --no-headers 2>/dev/null | wc -l)
  if [ "${count}" -ge 2 ]; then
    break
  fi
  echo "  waiting for 2 pods... (${count}/2) (${i}/60)"
  sleep 2
done
count=$(kubectl get pod -n default -l sandbox=juicefs-demo --no-headers 2>/dev/null | wc -l)
if [ "${count}" -lt 2 ]; then
  echo "ERROR: expected 2 sandbox pods, got ${count}"
  exit 1
fi

echo "Waiting for sandbox pods to be ready..."
kubectl wait --for=condition=ready pod -l sandbox=juicefs-demo -n default --timeout=120s

echo "=== Verifying JuiceFS: each pod uses its own subdir (user-1/conv-1, user-1/conv-2) ==="
POD1=$(kubectl get pods -n default -l user-id=user-1,conv-id=conv-1 -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl get pods -n default -l user-id=user-1,conv-id=conv-2 -o jsonpath='{.items[0].metadata.name}')
if [ -z "${POD1}" ] || [ -z "${POD2}" ]; then
  echo "ERROR: could not get pod names (POD1=${POD1:-<empty>}, POD2=${POD2:-<empty>})"
  exit 1
fi
# 卷内每 Pod 一目录（两级）：Pod1 挂载 subPath user-1/conv-1，Pod2 挂载 user-1/conv-2
TEST_FILE="/shared/juicefs-demo-test-$$.txt"
CONTENT1="Hello from ${POD1} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONTENT2="Hello from ${POD2} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

kubectl exec -n default "${POD1}" -- sh -c "printf '%s' \"${CONTENT1}\" > ${TEST_FILE}"
READ1=$(kubectl exec -n default "${POD1}" -- cat "${TEST_FILE}")
READ1_TRIMMED="${READ1%$'\n'}"
if [ "${READ1_TRIMMED}" = "${CONTENT1}" ]; then
  echo "Pod1 (${POD1}) subdir user-1/conv-1 OK: write and read back."
else
  echo "Pod1 verification FAILED: expected '${CONTENT1}', got '${READ1_TRIMMED}'"
  exit 1
fi

kubectl exec -n default "${POD2}" -- sh -c "printf '%s' \"${CONTENT2}\" > ${TEST_FILE}"
READ2=$(kubectl exec -n default "${POD2}" -- cat "${TEST_FILE}")
READ2_TRIMMED="${READ2%$'\n'}"
if [ "${READ2_TRIMMED}" = "${CONTENT2}" ]; then
  echo "Pod2 (${POD2}) subdir user-1/conv-2 OK: write and read back."
else
  echo "Pod2 verification FAILED: expected '${CONTENT2}', got '${READ2_TRIMMED}'"
  exit 1
fi

kubectl exec -n default "${POD1}" -- rm -f "${TEST_FILE}"
kubectl exec -n default "${POD2}" -- rm -f "${TEST_FILE}"
echo "JuiceFS verification OK: user-1 has two conv dirs (user-1/conv-1, user-1/conv-2), each pod uses its own."

# Cleanup function: delete Sandbox CRs first (pods go away), then PVC, then infra
cleanup() {
  echo "Cleaning up JuiceFS shared sandboxes and infra..."
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-shared-1.yaml"
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-shared-2.yaml"
  # Wait for pods to terminate so PVC can be released
  kubectl wait --for=delete pod -l sandbox=juicefs-demo -n default --timeout=60s 2>/dev/null || true
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

echo "Done. Two pods (${POD1}, ${POD2}) use JuiceFS PVC; subdirs user-1/conv-1 and user-1/conv-2 (user-id=user-1)."
echo "To cleanup later: uncomment 'trap cleanup EXIT' in this script and re-run, or run cleanup steps manually."
