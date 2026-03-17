# NFS Subdir External Provisioner 共享存储 Demo 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增一套与现有 JuiceFS 流程并行的、基于 `k8s-sigs.io/nfs-subdir-external-provisioner` 的一键部署与验证流程；NFS 服务器可部署在 K8s 集群外，不修改现有脚本与代码。

**Architecture:** 在 `examples/python-runtime-sandbox` 下新增目录 `nfs-shared/` 和新脚本 `run-test-kind-nfs.sh`。脚本复用与 JuiceFS 版本相同的整体步骤：Kind + agent-sandbox + 共享存储 + 三个 Sandbox Pod（两个 subPath + 一个根目录），仅将存储后端从 JuiceFS CSI 换为 NFS subdir provisioner；NFS 服务器地址与路径通过环境变量配置，支持集群外 NFS。

**Tech Stack:** Kubernetes (Kind), agent-sandbox CRD, k8s-sigs/nfs-subdir-external-provisioner, Bash。NFS 服务器可由用户自备（集群外），或由脚本在未设置环境变量时在集群内自动部署用于本地演示。

---

## 一、与现有 JuiceFS 流程的关系

| 项目 | JuiceFS 流程（不修改） | 本计划（新增） |
|------|------------------------|----------------|
| 脚本 | `run-test-kind-juicefs.sh` | `run-test-kind-nfs.sh` |
| 资源目录 | `juicefs-shared/` | `nfs-shared/` |
| Provisioner | JuiceFS CSI | k8s-sigs.io/nfs-subdir-external-provisioner |
| 存储依赖 | MinIO + Redis + JuiceFS CSI | 外部 NFS 或脚本内建“本地部署 NFS” |

### 两个脚本同机运行是否有冲突

**会冲突的情况：** 两个脚本都通过 `make deploy-kind` 创建/更新集群，而 Makefile 里固定了 `KIND_CLUSTER=agent-sandbox`，且 `deploy-kind` 使用 `--recreate`，会先删再建同名集群。因此：

- **先后运行**：先跑 JuiceFS 再跑 NFS（或反过来），后跑的那个会执行 `make deploy-kind`，集群被 `--recreate` 重建，前一个脚本部署的所有资源（JuiceFS 或 NFS）都会消失，**最终只剩后跑的那个脚本的 demo**。
- **同时运行**：两个进程同时调 `make deploy-kind`，会争抢同一集群名，可能报错或状态错乱。

**不冲突的部分：** 若能在**同一集群内**只做“追加部署”（不再执行会重建集群的步骤），则两边资源本身不重名：JuiceFS 用 `juicefs-infra` namespace、`juicefs-demo-pvc`、`sandbox=juicefs-demo`；NFS 用 default 的 `nfs-demo-pvc`、`sandbox=nfs-demo` 等，可以共存。

**若要两个 demo 同时保留：** 需要两个不同的 Kind 集群。例如 NFS 脚本不调 `make deploy-kind`，而是用单独集群名（如 `agent-sandbox-nfs`）自己建集群（需 Makefile 支持传入 `KIND_CLUSTER` 或脚本直接调 `create-kind-cluster` 并传入该名），这样 JuiceFS 用 `agent-sandbox`，NFS 用 `agent-sandbox-nfs`，两套脚本可先后或分别运行，互不覆盖。本计划不实现“双集群”逻辑，仅在此说明冲突与可选方案；实现时 NFS 脚本与 JuiceFS 脚本一样使用默认集群名 `agent-sandbox`，用户若需同时保留两套 demo，需自行用不同 `KIND_CLUSTER` 或错开运行/清理顺序。

---

## 二、NFS 服务器与 Kind 的约定

- **集群外 NFS：** 用户设置 `NFS_SERVER`、`NFS_PATH`（例如宿主机 IP 或 `host.docker.internal`），脚本将二者写入 provisioner 的 Deployment 环境变量与 volume，不再部署 NFS 服务。
- **本地部署 NFS（脚本内建）：** 当未设置 `NFS_SERVER` 或 `NFS_PATH` 时，脚本在集群内自动部署一个 NFS 服务（Deployment + Service + 导出路径），并令 `NFS_SERVER` 指向该 Service、`NFS_PATH` 为导出路径，再部署 provisioner。该逻辑写在 `run-test-kind-nfs.sh` 内（例如用 heredoc 或内联 YAML 通过 `kubectl apply -f -`），不单独增加 Task 6、不新增独立 `nfs-server-demo.yaml` 等文件。

---

## 三、资源与命名约定（本 NFS Demo）

| 资源 | 规范 | 本示例取值 |
|------|------|------------|
| 前缀 | `<prefix>` | `nfs-demo` |
| StorageClass | 与 provisioner 一致 | `nfs-client`（或 `nfs-demo-sc`） |
| PVC | `<prefix>-pvc` | `nfs-demo-pvc` |
| Sandbox（2 个 subPath + 1 个根目录） | 与 JuiceFS 语义一致 | `nfs-demo-sandbox-user-1-conv-1`、`nfs-demo-sandbox-user-1-conv-2`、`nfs-demo-sandbox-csg-hub-server` |
| Pod 标签（共享组） | `sandbox=<prefix>` | `sandbox=nfs-demo` |
| subPath | 与 JuiceFS 一致 | `user-1/conv-1`、`user-1/conv-2`；csg-hub-server 不设 subPath |

---

## 四、任务列表（Bite-Sized）

### Task 1: 创建 nfs-shared 目录与 RBAC

**Files:**
- Create: `examples/python-runtime-sandbox/nfs-shared/rbac.yaml`

**Step 1: 编写 rbac.yaml**

基于 [nfs-subdir-external-provisioner/deploy/rbac.yaml](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/blob/master/deploy/rbac.yaml)，将 provisioner 部署到固定 namespace（建议 `kube-system` 或 `default`）。若选 `kube-system`，需把 rbac 中所有 `namespace: default` 改为 `namespace: kube-system`，并在后续 Deployment、StorageClass 中一致使用该 namespace。

以下示例使用 `default` namespace（与官方 deploy 一致），便于与 Kind 默认行为一致。

```yaml
# examples/python-runtime-sandbox/nfs-shared/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: default
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: default
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: default
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: default
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: default
roleRef:
  kind: Role
  name: leader-locking-nfs-client-provisioner
  apiGroup: rbac.authorization.k8s.io
```

**Step 2: 提交**

```bash
git add examples/python-runtime-sandbox/nfs-shared/rbac.yaml
git commit -m "feat(nfs-demo): add RBAC for nfs-subdir-external-provisioner"
```

---

### Task 2: 创建 NFS Provisioner Deployment 模板

**Files:**
- Create: `examples/python-runtime-sandbox/nfs-shared/provisioner-deployment.yaml`

**Step 1: 编写 provisioner-deployment.yaml**

Provisioner 的 `NFS_SERVER` 与 `NFS_PATH` 由脚本通过 `envsubst` 或 `sed` 在运行时替换（见 Task 5）。此处使用占位符 `__NFS_SERVER__` 与 `__NFS_PATH__`，脚本中替换为 `$NFS_SERVER`、`$NFS_PATH`。

```yaml
# examples/python-runtime-sandbox/nfs-shared/provisioner-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  labels:
    app: nfs-client-provisioner
  namespace: default
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: k8s-sigs.io/nfs-subdir-external-provisioner
            - name: NFS_SERVER
              value: __NFS_SERVER__
            - name: NFS_PATH
              value: __NFS_PATH__
      volumes:
        - name: nfs-client-root
          nfs:
            server: __NFS_SERVER__
            path: __NFS_PATH__
```

**Step 2: 提交**

```bash
git add examples/python-runtime-sandbox/nfs-shared/provisioner-deployment.yaml
git commit -m "feat(nfs-demo): add NFS provisioner deployment template"
```

---

### Task 3: 创建 StorageClass 与 PVC

**Files:**
- Create: `examples/python-runtime-sandbox/nfs-shared/storageclass.yaml`
- Create: `examples/python-runtime-sandbox/nfs-shared/pvc.yaml`

**Step 1: 编写 storageclass.yaml**

```yaml
# examples/python-runtime-sandbox/nfs-shared/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-demo-sc
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "false"
```

**Step 2: 编写 pvc.yaml**

```yaml
# examples/python-runtime-sandbox/nfs-shared/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-demo-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-demo-sc
```

**Step 3: 提交**

```bash
git add examples/python-runtime-sandbox/nfs-shared/storageclass.yaml examples/python-runtime-sandbox/nfs-shared/pvc.yaml
git commit -m "feat(nfs-demo): add StorageClass and PVC for shared NFS"
```

---

### Task 4: 创建三个 Sandbox 清单（subPath x2 + 根目录 x1）

**Files:**
- Create: `examples/python-runtime-sandbox/nfs-shared/sandbox-shared-1.yaml`
- Create: `examples/python-runtime-sandbox/nfs-shared/sandbox-shared-2.yaml`
- Create: `examples/python-runtime-sandbox/nfs-shared/sandbox-csg-hub-server.yaml`

**Step 1: 编写 sandbox-shared-1.yaml**

与 JuiceFS 版本语义一致：挂载同一 PVC，subPath 为 `user-1/conv-1`，仅改 name/label/claimName/storage 相关命名为 nfs-demo。

```yaml
# examples/python-runtime-sandbox/nfs-shared/sandbox-shared-1.yaml
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: nfs-demo-sandbox-user-1-conv-1
  namespace: default
spec:
  podTemplate:
    metadata:
      labels:
        sandbox: nfs-demo
        user-id: "user-1"
        conv-id: "conv-1"
    spec:
      containers:
        - name: python-sandbox
          image: sandbox-runtime:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8888
          volumeMounts:
            - name: shared-data
              mountPath: /shared
              subPath: user-1/conv-1
      volumes:
        - name: shared-data
          persistentVolumeClaim:
            claimName: nfs-demo-pvc
```

**Step 2: 编写 sandbox-shared-2.yaml**

subPath 为 `user-1/conv-2`，其余同上。

```yaml
# examples/python-runtime-sandbox/nfs-shared/sandbox-shared-2.yaml
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: nfs-demo-sandbox-user-1-conv-2
  namespace: default
spec:
  podTemplate:
    metadata:
      labels:
        sandbox: nfs-demo
        user-id: "user-1"
        conv-id: "conv-2"
    spec:
      containers:
        - name: python-sandbox
          image: sandbox-runtime:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8888
          volumeMounts:
            - name: shared-data
              mountPath: /shared
              subPath: user-1/conv-2
      volumes:
        - name: shared-data
          persistentVolumeClaim:
            claimName: nfs-demo-pvc
```

**Step 3: 编写 sandbox-csg-hub-server.yaml**

不设 subPath，挂载 PVC 根目录，与 JuiceFS 版 csg-hub-server 行为一致。

```yaml
# examples/python-runtime-sandbox/nfs-shared/sandbox-csg-hub-server.yaml
apiVersion: agents.x-k8s.io/v1alpha1
kind: Sandbox
metadata:
  name: nfs-demo-sandbox-csg-hub-server
  namespace: default
spec:
  podTemplate:
    metadata:
      labels:
        sandbox: nfs-demo
        app: csg-hub-server
    spec:
      containers:
        - name: python-sandbox
          image: sandbox-runtime:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8888
          volumeMounts:
            - name: shared-data
              mountPath: /shared
      volumes:
        - name: shared-data
          persistentVolumeClaim:
            claimName: nfs-demo-pvc
```

**Step 4: 提交**

```bash
git add examples/python-runtime-sandbox/nfs-shared/sandbox-shared-1.yaml examples/python-runtime-sandbox/nfs-shared/sandbox-shared-2.yaml examples/python-runtime-sandbox/nfs-shared/sandbox-csg-hub-server.yaml
git commit -m "feat(nfs-demo): add three Sandbox manifests (two subPath + root)"
```

---

### Task 5: 编写 run-test-kind-nfs.sh 主脚本

**Files:**
- Create: `examples/python-runtime-sandbox/run-test-kind-nfs.sh`

**Step 1: 实现脚本骨架与“本地部署 NFS”能力**

- 与 `run-test-kind-juicefs.sh` 结构对齐：`set -e`、`KIND_CLUSTER_NAME`、`SCRIPT_DIR`、`NFS_DIR="${SCRIPT_DIR}/nfs-shared"`。
- **NFS 来源逻辑（必须实现）：**
  - 若已设置 `NFS_SERVER` 且已设置 `NFS_PATH`：直接使用，不部署 NFS。
  - 若未设置：在集群内部署 NFS 服务（脚本内嵌 YAML，例如用 `cat <<'EOF' | kubectl apply -f -` 或临时文件），使用常见 NFS 服务镜像（如 `itsthenetwork/nfs-server-alpine` 或 `gcr.io/k8s-staging-sig-storage/nfs-server`）。部署后等待 NFS Server Pod 及 Service 就绪，将 `NFS_SERVER` 设为该 Service 的 DNS 名（如 `nfs-server.default.svc.cluster.local` 或 `nfs-server.default`），`NFS_PATH` 设为该镜像的导出路径（如 `/exports`）。cleanup 时需删除该 NFS Deployment/Service（仅当本次是由脚本创建时才删除）。
- 步骤顺序：`make build`、`make deploy-kind` → 构建并加载 `sandbox-runtime` 镜像 → **若未设置 NFS：部署 in-cluster NFS 并导出 NFS_SERVER、NFS_PATH** → 应用 RBAC → 使用 `sed` 将 `__NFS_SERVER__`/`__NFS_PATH__` 替换为实际值后 apply provisioner Deployment → 等待 provisioner 就绪 → 应用 StorageClass、PVC → 等待 PVC Bound → 等待 agent-sandbox-controller 就绪 → 应用三个 Sandbox → 等待 3 个 Pod 就绪。

**Step 2: 实现验证逻辑**

- 与 JuiceFS 脚本一致：POD1（user-1/conv-1）、POD2（user-1/conv-2）、POD_HUB（csg-hub-server）。
- 在 POD1 写文件到 `/shared/pod1-wrote-$$.txt`，POD2 写文件到 `/shared/pod2-wrote-$$.txt`。
- 在 POD_HUB 读取 `/shared/user-1/conv-1/pod1-wrote-$$.txt` 与 `/shared/user-1/conv-2/pod2-wrote-$$.txt`，校验内容一致后删除临时文件。

**Step 3: 实现 cleanup 函数**

- 删除三个 Sandbox 清单 → 等待 Pod 删除 → 删除 PVC → 删除 StorageClass → 删除 provisioner Deployment → **若本次运行是由脚本部署了 in-cluster NFS，则删除该 NFS Deployment/Service** → 删除 RBAC → 删除 controller 与 CRD → `make delete-kind`。不删除或修改任何 `juicefs-shared/` 或 `run-test-kind-juicefs.sh`。

**Step 4: 脚本内 NFS 占位符与“未设置则部署本地 NFS”示例**

- 若已设置 `NFS_SERVER`、`NFS_PATH`，直接使用并标记“未部署本地 NFS”（cleanup 时不删 NFS）。
- 若未设置，在脚本内用内联 YAML 部署 NFS Server（固定命名如 `nfs-server`、namespace `default`），等待就绪后赋值，例如：

```bash
# 示例（在脚本中）：未设置时部署 in-cluster NFS
DEPLOYED_NFS=false
if [ -z "${NFS_SERVER}" ] || [ -z "${NFS_PATH}" ]; then
  echo "NFS_SERVER/NFS_PATH not set, deploying in-cluster NFS server..."
  # 在脚本内用 heredoc 输出 NFS Server 的 Deployment + Service YAML（镜像如 itsthenetwork/nfs-server-alpine，导出 /exports），再 kubectl apply -f -
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
          image: itsthenetwork/nfs-server-alpine
          env:
            - name: SHARED_EXPORT_PATH
              value: /exports
          # ... 其他必要 volumeMounts
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
  NFS_SERVER="nfs-server.default.svc.cluster.local"
  NFS_PATH="/exports"
  DEPLOYED_NFS=true
fi
sed -e "s/__NFS_SERVER__/${NFS_SERVER}/g" -e "s|__NFS_PATH__|${NFS_PATH}|g" \
  "${NFS_DIR}/provisioner-deployment.yaml" | kubectl apply -f -
# cleanup 时：若 DEPLOYED_NFS=true，则 kubectl delete deployment nfs-server svc/nfs-server ...
```

**Step 5: 提交**

```bash
git add examples/python-runtime-sandbox/run-test-kind-nfs.sh
git commit -m "feat(nfs-demo): add run-test-kind-nfs.sh for NFS subdir provisioner flow"
```

---

**说明：** 不实施独立 Task 6；本地部署 NFS 的能力已包含在 Task 5 的脚本内（未设置 `NFS_SERVER`/`NFS_PATH` 时由脚本内嵌 YAML 部署 in-cluster NFS 并清理）。

---

## 五、验收与测试

- 在不修改 `run-test-kind-juicefs.sh` 与 `juicefs-shared/*` 的前提下，仅新增/修改 `nfs-shared/*` 与 `run-test-kind-nfs.sh`。
- **使用外部 NFS：** 用户设置 `NFS_SERVER`、`NFS_PATH` 后执行 `./run-test-kind-nfs.sh`，应完成：Provisioner 就绪 → PVC Bound → 三个 Sandbox Pod Running → 验证两个 subPath 写入被 csg-hub-server 根目录读取通过。
- **本地部署 NFS：** 不设置 `NFS_SERVER`/`NFS_PATH` 直接执行 `./run-test-kind-nfs.sh` 时，脚本应在集群内自动部署 NFS 服务并跑通上述验证；cleanup 时删除本次部署的 NFS 资源。

---

## 六、执行选项

计划已保存到 `docs/plans/2026-03-17-nfs-subdir-provisioner-demo.md`。可选两种执行方式：

1. **Subagent-Driven（本会话）** — 按任务派发子 agent，每步审查后再进行下一步，迭代快。
2. **Parallel Session（新会话）** — 在新会话中打开本计划，使用 @executing-plans 按任务批量执行并在检查点停顿。

若选择 Subagent-Driven，请使用 superpowers:subagent-driven-development 在本会话内按任务执行。若选择新会话，请在新会话中引用本计划并启用 executing-plans。
