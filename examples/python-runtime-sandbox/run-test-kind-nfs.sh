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
# 一键部署：**独立 Kind 集群** agent-sandbox-nfs + agent-sandbox + NFS subdir provisioner + 三个共享 NFS 的 Sandbox Pod。
# 与 run-test-kind-juicefs.sh 不冲突：使用集群名 agent-sandbox-nfs 与独立 kubeconfig（bin/KUBECONFIG_NFS），
# 不触碰第一个集群 agent-sandbox。NFS 可集群外（设置 NFS_SERVER、NFS_PATH）或由脚本在集群内自动部署。
#
# 用法：
#NFS_SERVER=192.168.3.54 NFS_PATH=/srv/nfs/exports ./run-test-kind-nfs.sh
#   外部 NFS:  NFS_SERVER=your-nfs-host NFS_PATH=/exported/path ./run-test-kind-nfs.sh
#   本地 NFS:  不设置 NFS_SERVER/NFS_PATH，脚本会在集群内部署 NFS 服务并验证。

set -e

# 第二个集群：默认 agent-sandbox-nfs，与 JuiceFS 的 agent-sandbox 分离
export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-agent-sandbox-nfs}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFS_DIR="${SCRIPT_DIR}/nfs-shared"
REPO_ROOT="${SCRIPT_DIR}/../.."
# 独立 kubeconfig，不覆盖第一个集群的 bin/KUBECONFIG
KUBECONFIG_NFS="${REPO_ROOT}/bin/KUBECONFIG_NFS"
KUBECONFIG_NFS_ABS="$(cd "${REPO_ROOT}" && pwd)/bin/KUBECONFIG_NFS"
export KUBECONFIG="${KUBECONFIG_NFS}"

cd "${REPO_ROOT}"
make build

echo "=== Creating Kind cluster ${KIND_CLUSTER_NAME} (separate from agent-sandbox) ==="
./dev/tools/create-kind-cluster --recreate "${KIND_CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_NFS}"
./dev/tools/push-images --image-prefix=kind.local/ --kind-cluster-name="${KIND_CLUSTER_NAME}"
./dev/tools/deploy-to-kube --image-prefix=kind.local/

cd "${SCRIPT_DIR}"

echo "Building sandbox-runtime image..."
docker build -t sandbox-runtime .

echo "Loading sandbox-runtime image into kind cluster ${KIND_CLUSTER_NAME}..."
kind load docker-image sandbox-runtime:latest --name "${KIND_CLUSTER_NAME}"

# --- NFS 来源：未设置则部署 in-cluster NFS ---
DEPLOYED_NFS=false
if [ -z "${NFS_SERVER}" ] || [ -z "${NFS_PATH}" ]; then
  echo "NFS_SERVER/NFS_PATH not set, deploying in-cluster NFS server..."
  kubectl apply -f - <<'NFSYAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-server
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-server
  template:
    metadata:
      labels:
        app: nfs-server
    spec:
      containers:
        - name: nfs
          image: itsthenetwork/nfs-server-alpine:latest
          securityContext:
            privileged: true
          env:
            - name: SHARED_DIRECTORY
              value: "/exports"
          volumeMounts:
            - name: exports
              mountPath: /exports
          # 等 NFS 端口 2049 真正监听后再标 Ready，避免 provisioner 挂载时 "Resource temporarily unavailable"
          startupProbe:
            tcpSocket:
              port: 2049
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            tcpSocket:
              port: 2049
            initialDelaySeconds: 2
            periodSeconds: 2
      volumes:
        - name: exports
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: nfs-server
  namespace: default
spec:
  selector:
    app: nfs-server
  ports:
    - port: 2049
      name: nfs
NFSYAML
  kubectl wait --for=condition=available deployment/nfs-server -n default --timeout=120s
  # readinessProbe 已保证 2049 在监听；再等几秒让 export 完全就绪，减少 mount "Resource temporarily unavailable"
  echo "Waiting 15s for NFS export to be fully ready..."
  sleep 15
  NFS_SERVER="nfs-server.default.svc.cluster.local"
  # Alpine 镜像导出 SHARED_DIRECTORY=/exports；部分环境需用 /exports 才能挂载成功
  NFS_PATH="/exports"
  DEPLOYED_NFS=true
fi

echo "=== Deploying NFS provisioner RBAC ==="
kubectl apply -f "${NFS_DIR}/rbac.yaml"

echo "=== Deploying NFS subdir external provisioner (server=${NFS_SERVER}, path=${NFS_PATH}) ==="
sed -e "s/__NFS_SERVER__/${NFS_SERVER}/g" -e "s|__NFS_PATH__|${NFS_PATH}|g" \
  "${NFS_DIR}/provisioner-deployment.yaml" | kubectl apply -f -

echo "Waiting for NFS provisioner to be ready (mount may take a while)..."
if ! kubectl wait --for=condition=available deployment/nfs-client-provisioner -n default --timeout=180s 2>/dev/null; then
  echo "ERROR: NFS provisioner did not become ready. In-cluster NFS may not support your environment (e.g. overlayfs)."
  echo "Diagnose: KUBECONFIG=${KUBECONFIG_NFS_ABS} kubectl describe pod -n default -l app=nfs-client-provisioner"
  echo "          KUBECONFIG=${KUBECONFIG_NFS_ABS} kubectl get events -n default --sort-by='.lastTimestamp'"
  echo "Workaround: Use an external NFS server: NFS_SERVER=<host> NFS_PATH=/path ./run-test-kind-nfs.sh"
  exit 1
fi

echo "=== Deploying StorageClass and PVC ==="
kubectl apply -f "${NFS_DIR}/storageclass.yaml"
kubectl apply -f "${NFS_DIR}/pvc.yaml"

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/nfs-demo-pvc -n default --timeout=120s

echo "=== Deploying NFS root PV/PVC (hub 挂载整个 NAS) ==="
sed -e "s/__NFS_SERVER__/${NFS_SERVER}/g" -e "s|__NFS_PATH__|${NFS_PATH}|g" \
  "${NFS_DIR}/nfs-root-pv.yaml" | kubectl apply -f -
kubectl apply -f "${NFS_DIR}/nfs-root-pvc.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/nfs-root-pvc -n default --timeout=60s

echo "Waiting for agent-sandbox-controller to be ready..."
kubectl wait --for=condition=available deployment/agent-sandbox-controller -n agent-sandbox-system --timeout=120s

echo "=== Deploying three Sandbox pods with shared NFS PVC (two subPath + csg-hub-server root) ==="
kubectl apply -f "${NFS_DIR}/sandbox-shared-1.yaml"
kubectl apply -f "${NFS_DIR}/sandbox-shared-2.yaml"
kubectl apply -f "${NFS_DIR}/sandbox-csg-hub-server.yaml"

echo "Waiting for sandbox pods to be created..."
for i in $(seq 1 60); do
  count=$(kubectl get pod -n default -l sandbox=nfs-demo --no-headers 2>/dev/null | wc -l)
  if [ "${count}" -ge 3 ]; then
    break
  fi
  echo "  waiting for 3 pods... (${count}/3) (${i}/60)"
  sleep 2
done
count=$(kubectl get pod -n default -l sandbox=nfs-demo --no-headers 2>/dev/null | wc -l)
if [ "${count}" -lt 3 ]; then
  echo "ERROR: expected 3 sandbox pods, got ${count}"
  exit 1
fi

echo "Waiting for sandbox pods to be ready..."
kubectl wait --for=condition=ready pod -l sandbox=nfs-demo -n default --timeout=120s

echo "=== Verifying NFS: Pod1/Pod2 subPath (user-1/conv-1, conv-2); csg-hub-server mounts entire NAS ==="
POD1=$(kubectl get pods -n default -l user-id=user-1,conv-id=conv-1 -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl get pods -n default -l user-id=user-1,conv-id=conv-2 -o jsonpath='{.items[0].metadata.name}')
POD_HUB=$(kubectl get pods -n default -l app=csg-hub-server -o jsonpath='{.items[0].metadata.name}')
if [ -z "${POD1}" ] || [ -z "${POD2}" ] || [ -z "${POD_HUB}" ]; then
  echo "ERROR: could not get pod names (POD1=${POD1:-<empty>}, POD2=${POD2:-<empty>}, POD_HUB=${POD_HUB:-<empty>})"
  exit 1
fi

# hub 挂载整个 NFS 根，子目录为 provisioner 创建的 default-nfs-demo-pvc-<uid>
NFS_PVC_SUBDIR=$(kubectl exec -n default "${POD_HUB}" -- ls /shared 2>/dev/null | head -1)
if [ -z "${NFS_PVC_SUBDIR}" ]; then
  echo "ERROR: csg-hub-server /shared is empty or not readable"
  exit 1
fi
echo "NFS root subdir for demo PVC: ${NFS_PVC_SUBDIR}"

FILE1="/shared/pod1-wrote-$$.txt"
FILE2="/shared/pod2-wrote-$$.txt"
CONTENT1="Written by ${POD1} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONTENT2="Written by ${POD2} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

kubectl exec -n default "${POD1}" -- sh -c "printf '%s' \"${CONTENT1}\" > ${FILE1}"
kubectl exec -n default "${POD2}" -- sh -c "printf '%s' \"${CONTENT2}\" > ${FILE2}"
echo "Pod1 wrote to subPath user-1/conv-1, Pod2 to user-1/conv-2."

HUB_PATH1="/shared/${NFS_PVC_SUBDIR}/user-1/conv-1/${FILE1##*/}"
HUB_PATH2="/shared/${NFS_PVC_SUBDIR}/user-1/conv-2/${FILE2##*/}"
READ_BY_HUB1=$(kubectl exec -n default "${POD_HUB}" -- cat "${HUB_PATH1}" 2>/dev/null || true)
READ_BY_HUB1_TRIMMED="${READ_BY_HUB1%$'\n'}"
if [ "${READ_BY_HUB1_TRIMMED}" = "${CONTENT1}" ]; then
  echo "csg-hub-server (${POD_HUB}) read Pod1's file at ${HUB_PATH1} OK."
else
  echo "Verification FAILED: csg-hub-server expected '${CONTENT1}', got '${READ_BY_HUB1_TRIMMED}'"
  exit 1
fi

READ_BY_HUB2=$(kubectl exec -n default "${POD_HUB}" -- cat "${HUB_PATH2}" 2>/dev/null || true)
READ_BY_HUB2_TRIMMED="${READ_BY_HUB2%$'\n'}"
if [ "${READ_BY_HUB2_TRIMMED}" = "${CONTENT2}" ]; then
  echo "csg-hub-server (${POD_HUB}) read Pod2's file at ${HUB_PATH2} OK."
else
  echo "Verification FAILED: csg-hub-server expected '${CONTENT2}', got '${READ_BY_HUB2_TRIMMED}'"
  exit 1
fi

kubectl exec -n default "${POD1}" -- rm -f "${FILE1}"
kubectl exec -n default "${POD2}" -- rm -f "${FILE2}"
echo "NFS verification OK: two pods use separate subPaths; csg-hub-server (entire NAS mount) sees both."

cleanup() {
  echo "Cleaning up NFS shared sandboxes and infra..."
  kubectl delete --timeout=30s --ignore-not-found -f "${NFS_DIR}/sandbox-shared-1.yaml"
  kubectl delete --timeout=30s --ignore-not-found -f "${NFS_DIR}/sandbox-shared-2.yaml"
  kubectl delete --timeout=30s --ignore-not-found -f "${NFS_DIR}/sandbox-csg-hub-server.yaml"
  kubectl wait --for=delete pod -l sandbox=nfs-demo -n default --timeout=60s 2>/dev/null || true
  kubectl delete --timeout=30s --ignore-not-found -f "${NFS_DIR}/pvc.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${NFS_DIR}/nfs-root-pvc.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${NFS_DIR}/nfs-root-pv.yaml"
  kubectl delete --timeout=10s --ignore-not-found -f "${NFS_DIR}/storageclass.yaml"
  kubectl delete --timeout=10s --ignore-not-found deployment/nfs-client-provisioner -n default
  if [ "${DEPLOYED_NFS}" = true ]; then
    kubectl delete --timeout=10s --ignore-not-found deployment/nfs-server -n default
    kubectl delete --timeout=10s --ignore-not-found svc/nfs-server -n default
  fi
  kubectl delete --timeout=10s --ignore-not-found -f "${NFS_DIR}/rbac.yaml"
  kubectl delete --timeout=10s --ignore-not-found deployment agent-sandbox-controller -n agent-sandbox-system
  kubectl delete --timeout=10s --ignore-not-found crd sandboxes.agents.x-k8s.io
  echo "Deleting kind cluster ${KIND_CLUSTER_NAME}..."
  kind delete cluster --name "${KIND_CLUSTER_NAME}"
}

# 取消注释下一行则脚本结束时自动清理
# trap cleanup EXIT

echo "Done. Cluster: ${KIND_CLUSTER_NAME}. Three pods: ${POD1}, ${POD2} (subPath), ${POD_HUB} (csg-hub-server, root). One PVC, shared NFS."
echo "To cleanup: uncomment 'trap cleanup EXIT' and re-run, or run: kind delete cluster --name ${KIND_CLUSTER_NAME} (and delete remaining resources as needed)."
