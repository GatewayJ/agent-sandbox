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
# 一键部署：Kind 集群 + agent-sandbox + MinIO + Redis + JuiceFS CSI + 三个共享 JuiceFS 的 Sandbox Pod（两个子目录 + csg-hub-server 根目录）
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
#
# 8) 在 K8s 集群外（本机）访问同一 JuiceFS：宿主机装 JuiceFS 客户端，把 Redis/MinIO 通过 port-forward 暴露到本机，
#    并让集群内域名解析到 127.0.0.1（元数据里存的 bucket 是集群内 MinIO 域名，必须能解析）。
#    a) 安装 JuiceFS 客户端: https://juicefs.com/docs/zh/community/installation
#       (例: curl -sSL https://d.juicefs.com/install | sh)
#    b) 本机 hosts 增加（使集群内域名指向本机，port-forward 后即可访问）：
#       127.0.0.1 redis.juicefs-infra.svc.cluster.local minio.juicefs-infra.svc.cluster.local
#    c) 两个终端或后台保持 port-forward：
#       kubectl port-forward -n juicefs-infra svc/redis 6379:6379
#       kubectl port-forward -n juicefs-infra svc/minio 9000:9000
#    d) 挂载（与 CSI 共用同一 Redis 元数据，看到同一文件系统）：
#       juicefs mount redis://redis.juicefs-infra.svc.cluster.local:6379/0 /mnt/jfs
#       挂载后根目录下为 PV 子目录：若 pathPattern 生效则为 juicefs-default-juicefs-demo-pvc，
#       未生效则为默认的 pvc-<PVC_UID>（pathPattern 仅在新创建 PV 时生效，且依赖 CSI 版本支持）。
#    卸载: fusermount -u /mnt/jfs  或  umount /mnt/jfs

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
# 使用默认 csi-provisioner（CreateVolume），pathPattern 不生效，JuiceFS 内目录名为 pvc-<UUID>。
# 先 apply StorageClass 再 apply PVC；若集群中已存在同名 PVC 则不会重新 provision。
kubectl apply -f "${JUICEFS_DIR}/juicefs-storageclass.yaml"
kubectl apply -f "${JUICEFS_DIR}/juicefs-pvc.yaml"

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/juicefs-demo-pvc -n default --timeout=120s

echo "Waiting for agent-sandbox-controller to be ready..."
kubectl wait --for=condition=available deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=120s

echo "=== Deploying three Sandbox pods with shared JuiceFS PVC (two subPath + csg-hub-server root) ==="
kubectl apply -f "${JUICEFS_DIR}/sandbox-shared-1.yaml"
kubectl apply -f "${JUICEFS_DIR}/sandbox-shared-2.yaml"
kubectl apply -f "${JUICEFS_DIR}/sandbox-csg-hub-server.yaml"

echo "Waiting for sandbox pods to be created..."
for i in $(seq 1 60); do
  count=$(kubectl get pod -n default -l sandbox=juicefs-demo --no-headers 2>/dev/null | wc -l)
  if [ "${count}" -ge 3 ]; then
    break
  fi
  echo "  waiting for 3 pods... (${count}/3) (${i}/60)"
  sleep 2
done
count=$(kubectl get pod -n default -l sandbox=juicefs-demo --no-headers 2>/dev/null | wc -l)
if [ "${count}" -lt 3 ]; then
  echo "ERROR: expected 3 sandbox pods, got ${count}"
  exit 1
fi

echo "Waiting for sandbox pods to be ready..."
kubectl wait --for=condition=ready pod -l sandbox=juicefs-demo -n default --timeout=120s

echo "=== Verifying JuiceFS: Pod1/Pod2 each use subPath (user-1/conv-1, conv-2); csg-hub-server mounts root ==="
POD1=$(kubectl get pods -n default -l user-id=user-1,conv-id=conv-1 -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl get pods -n default -l user-id=user-1,conv-id=conv-2 -o jsonpath='{.items[0].metadata.name}')
POD_HUB=$(kubectl get pods -n default -l app=csg-hub-server -o jsonpath='{.items[0].metadata.name}')
if [ -z "${POD1}" ] || [ -z "${POD2}" ] || [ -z "${POD_HUB}" ]; then
  echo "ERROR: could not get pod names (POD1=${POD1:-<empty>}, POD2=${POD2:-<empty>}, POD_HUB=${POD_HUB:-<empty>})"
  exit 1
fi
# Pod1/Pod2 各挂载不同 subPath（user-1/conv-1、user-1/conv-2），不能互相读对方目录；由挂载根目录的 csg-hub-server 验证可见性
FILE1="/shared/pod1-wrote-$$.txt"
FILE2="/shared/pod2-wrote-$$.txt"
CONTENT1="Written by ${POD1} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONTENT2="Written by ${POD2} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

kubectl exec -n default "${POD1}" -- sh -c "printf '%s' \"${CONTENT1}\" > ${FILE1}"
kubectl exec -n default "${POD2}" -- sh -c "printf '%s' \"${CONTENT2}\" > ${FILE2}"
echo "Pod1 wrote to subPath user-1/conv-1, Pod2 to user-1/conv-2."

# csg-hub-server 挂载根目录，应能在 /shared/user-1/conv-1 与 /shared/user-1/conv-2 下看到上述文件
READ_BY_HUB1=$(kubectl exec -n default "${POD_HUB}" -- cat "/shared/user-1/conv-1/${FILE1##*/}" 2>/dev/null || true)
READ_BY_HUB1_TRIMMED="${READ_BY_HUB1%$'\n'}"
if [ "${READ_BY_HUB1_TRIMMED}" = "${CONTENT1}" ]; then
  echo "csg-hub-server (${POD_HUB}) read Pod1's file at /shared/user-1/conv-1/ OK."
else
  echo "Verification FAILED: csg-hub-server expected '${CONTENT1}', got '${READ_BY_HUB1_TRIMMED}'"
  exit 1
fi

READ_BY_HUB2=$(kubectl exec -n default "${POD_HUB}" -- cat "/shared/user-1/conv-2/${FILE2##*/}" 2>/dev/null || true)
READ_BY_HUB2_TRIMMED="${READ_BY_HUB2%$'\n'}"
if [ "${READ_BY_HUB2_TRIMMED}" = "${CONTENT2}" ]; then
  echo "csg-hub-server (${POD_HUB}) read Pod2's file at /shared/user-1/conv-2/ OK."
else
  echo "Verification FAILED: csg-hub-server expected '${CONTENT2}', got '${READ_BY_HUB2_TRIMMED}'"
  exit 1
fi

kubectl exec -n default "${POD1}" -- rm -f "${FILE1}"
kubectl exec -n default "${POD2}" -- rm -f "${FILE2}"
echo "JuiceFS verification OK: two pods use separate subPaths; csg-hub-server (root mount) sees both."

# Cleanup function: delete Sandbox CRs first (pods go away), then PVC, then infra
cleanup() {
  echo "Cleaning up JuiceFS shared sandboxes and infra..."
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-shared-1.yaml"
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-shared-2.yaml"
  kubectl delete --timeout=30s --ignore-not-found -f "${JUICEFS_DIR}/sandbox-csg-hub-server.yaml"
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

echo "Done. Three pods: ${POD1}, ${POD2} (subPath), ${POD_HUB} (csg-hub-server, root). One PVC, shared JuiceFS."
echo "To cleanup later: uncomment 'trap cleanup EXIT' in this script and re-run, or run cleanup steps manually."
