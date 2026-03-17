# JuiceFS Demo 命名规范统一 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 `examples/python-runtime-sandbox/juicefs-shared` 下的 Sandbox、PVC、PV/JuiceFS 目录名及脚本中的引用统一到同一套命名规范，并在文档中明确多租户扩展方案：user-id → 桶 / Secret / StorageClass / PVC → 一卷；卷内每 Pod 一目录（= Pod 名）；Pod 名含 user-id。

**Architecture:** 本计划分三部分：**(1) 当前 Demo 命名规范** — 前缀 `juicefs-demo`，一个共享 PVC、两个 Sandbox，pathPattern 决定 JuiceFS 子目录；(2) **多租户扩展（仅设计说明，本次不实施）** — 一用户一桶/一卷，卷内每 Pod 一目录，目录名 = Pod 名，Pod 名含 user-id；(3) **本次实施任务** — Task 1～6 仅修改 Demo 的 YAML 与脚本，使命名统一。

**Tech Stack:** Kubernetes (Kind), agent-sandbox CRD, JuiceFS CSI, Bash.

---

## 文档结构说明

| 章节 | 内容 | 本次是否实施 |
|------|------|--------------|
| 一、当前 Demo 命名规范 | 前缀、PVC、Sandbox、标签、pathPattern | 是（Task 1～6） |
| 二、多租户扩展 | 一用户一桶/一卷，卷内每 Pod 一目录（目录名=Pod 名，Pod 名含 user-id） | 否，仅文档 |
| 三、本次实施任务（Task 1～6） | 修改 Demo 的 PVC/SC/Sandbox/脚本/README | 是 |

---

## 一、当前 Demo 命名规范（本示例采用）

**适用范围：** 当前仓库中的 `juicefs-shared` 示例 — 一个共享 PVC、两个 Sandbox Pod 共享同一 JuiceFS 目录。

| 资源 | 规范格式 | 本示例取值 |
|------|----------|------------|
| 前缀 | `<prefix>` | `juicefs-demo` |
| PVC | `<prefix>-pvc` | `juicefs-demo-pvc` |
| Sandbox 名（即 Pod 名，新建时一致） | `<prefix>-sandbox-<instance>` | `juicefs-demo-sandbox-1`, `juicefs-demo-sandbox-2` |
| Pod 标签（共享组） | `sandbox=<prefix>` | `sandbox=juicefs-demo` |
| Pod 标签（实例号） | `sandbox-instance=<n>` | `1`, `2` |
| JuiceFS PV 子目录 | pathPattern: `juicefs-${.pvc.namespace}-${.pvc.name}` | `juicefs-default-juicefs-demo-pvc` |
| Pod 标签（挂载路径，与 pathPattern 一致） | `juicefs/pv-path=<pathPattern 结果>` | `juicefs-default-juicefs-demo-pvc` |

- StorageClass 名：`juicefs-sc`（集群级，与单次 demo 解耦）。  
- Secret 名：`juicefs-sc-secret`。

---

## 二、多租户扩展（一用户一桶/一卷，卷内每 Pod 一目录）

**适用场景：** 需要「一个用户一个 JuiceFS 卷」（更强隔离），且在该卷内「每个 Pod 占用一个子目录，目录名 = Pod 名」；Pod 名需含 user-id。

**模型：** 每用户一个 MinIO 桶、一个 JuiceFS 卷（共用 Redis 时用不同 DB 或 key 前缀区分）；该用户一个 PVC 挂载该卷；该用户所有 Pod 挂同一 PVC；卷内每个 Pod 使用一个子目录，目录名 = Pod 名（Pod 名含 user-id）。

### 2.1 实现要点

1. **每用户一个 MinIO 桶**  
   用与现有 bucket-init 类似的 **Sidecar 或 Job**，在用户首次使用时创建该用户的 bucket（桶名 = `<user-id>` 或 `<prefix>-<user-id>`）。可由控制器在创建该用户 PVC 前跑一次 Job，或由统一入口在首次分配用户资源时触发。

2. **共用同一 Redis，按用户区分**  
   共用同一 Redis 实例，用 **不同 DB 号**（如 `redis://.../0`、`redis://.../1`）或 JuiceFS 支持的 **key 前缀** 区分用户，使每个用户对应一个独立的 JuiceFS 文件系统（一卷）。

3. **每用户一个 Secret**  
   Secret 名：`juicefs-secret-<user-id>`（例：`juicefs-secret-user123`）。内容含该用户的 `bucket`（MinIO 桶地址）、`metaurl`（Redis，按用户不同 DB 或前缀）、`access-key` / `secret-key`。置于 `kube-system` 或与 PVC 同 namespace，供 CSI provisioner 使用。

4. **每用户一个 StorageClass**  
   JuiceFS CSI 通过 StorageClass 的 parameters 中的 `provisioner-secret-name` / `provisioner-secret-namespace` 取 Secret，因此 **每用户一个 StorageClass**：名称 `juicefs-sc-<user-id>`，parameters 指向 `juicefs-secret-<user-id>`。用户创建 PVC 时使用 `storageClassName: juicefs-sc-user123`。

5. **卷内每 Pod 一目录（目录名 = Pod 名）**  
   该用户所有 Pod 挂载同一 PVC（同一卷），挂载点例如 `/shared`。每个 Pod 在卷内使用 **单独子目录，目录名 = 该 Pod 名**（Pod 名已含 user-id）。实现方式二选一：  
   - **volumeMount.subPath**：使用 downwardAPI 注入 `POD_NAME`，设 `subPath: $(POD_NAME)`（若 JuiceFS CSI 支持 subPath）。  
   - **应用层约定**：挂载点为 `/shared`，应用或 entrypoint 在启动时创建并只读写 `/shared/$(POD_NAME)`。

**本方案不使用 pathPattern 划分子目录**：一卷对应一个桶，卷内子目录由 Pod 的 subPath 或应用层按 Pod 名管理。

### 2.2 资源与命名对应关系

| 概念 | 命名 / 规则 | 示例 |
|------|-------------|------|
| 用户标识 | `<user-id>` | `user123` |
| MinIO 桶 | 与 user-id 一致或 `<prefix>-<user-id>` | `user123` |
| Secret | `juicefs-secret-<user-id>` | `juicefs-secret-user123` |
| StorageClass | `juicefs-sc-<user-id>` | `juicefs-sc-user123` |
| PVC | `<prefix>-pvc-<user-id>` | `juicefs-demo-pvc-user123` |
| Sandbox 名 / Pod 名 | **必须含 user-id**，格式 `<prefix>-sandbox-<user-id>-<conversation-id>` | `juicefs-demo-sandbox-user123-conv-abc` |
| 卷内 Pod 工作目录 | 卷内子目录，**目录名 = Pod 名** | `/shared/<pod-name>`，如 `/shared/juicefs-demo-sandbox-user123-conv-abc` |

**小结：** user123 → MinIO 桶 user123 → Secret juicefs-secret-user123 → StorageClass juicefs-sc-user123 → PVC juicefs-demo-pvc-user123 → 该用户的 Pod 挂此 PVC；一个用户一个卷，该用户每个 Pod 占用卷内一个目录，目录名 = Pod 名；Pod 名包含 user-id。

*多租户扩展的具体实现（Job 创建桶、按用户生成 Secret/StorageClass、Pod subPath 或应用层目录）作为后续独立 Implementation Plan 分步落地。*

---

## 三、本次实施任务（Task 1～6）

以下任务仅修改当前 Demo 的 YAML 与脚本，使命名符合「一、当前 Demo 命名规范」，不涉及多租户扩展的代码实现。

---

### Task 1: 更新 juicefs-pvc.yaml 的 PVC 名

**Files:**  
- Modify: `examples/python-runtime-sandbox/juicefs-shared/juicefs-pvc.yaml`

**Step 1: 修改 PVC metadata.name**  
将 `juicefs-shared-pvc` 改为 `juicefs-demo-pvc`。

```yaml
metadata:
  name: juicefs-demo-pvc
  namespace: default
```

**Step 2: 自检**  
确认 `storageClassName: juicefs-sc` 未改。

**Step 3: Commit**

```bash
git add examples/python-runtime-sandbox/juicefs-shared/juicefs-pvc.yaml
git commit -m "examples(juicefs): rename PVC to juicefs-demo-pvc for naming convention"
```

---

### Task 2: 更新 juicefs-storageclass.yaml 注释（pathPattern 说明）

**Files:**  
- Modify: `examples/python-runtime-sandbox/juicefs-shared/juicefs-storageclass.yaml`

**Step 1: 更新 pathPattern 注释**  
注释中明确本示例 pathPattern 结果为 `juicefs-default-juicefs-demo-pvc`。

```yaml
# 动态 PV 子目录命名：juicefs-<namespace>-<pvc-name>；本示例为 juicefs-default-juicefs-demo-pvc
pathPattern: "juicefs-${.pvc.namespace}-${.pvc.name}"
```

**Step 2: Commit**

```bash
git add examples/python-runtime-sandbox/juicefs-shared/juicefs-storageclass.yaml
git commit -m "examples(juicefs): align pathPattern comment with demo PVC name"
```

---

### Task 3: 更新 sandbox-shared-1.yaml 名称与标签

**Files:**  
- Modify: `examples/python-runtime-sandbox/juicefs-shared/sandbox-shared-1.yaml`

**Step 1: 修改 Sandbox 名与标签**  
- `metadata.name`: `sandbox-python-juicefs-1` → `juicefs-demo-sandbox-1`  
- `spec.podTemplate.metadata.labels.sandbox`: `python-juicefs-shared` → `juicefs-demo`  
- `spec.podTemplate.metadata.labels.juicefs/pv-path`: `juicefs-default-juicefs-shared-pvc` → `juicefs-default-juicefs-demo-pvc`  
- `volumes.persistentVolumeClaim.claimName`: `juicefs-shared-pvc` → `juicefs-demo-pvc`

**Step 2: Commit**

```bash
git add examples/python-runtime-sandbox/juicefs-shared/sandbox-shared-1.yaml
git commit -m "examples(juicefs): apply naming convention to sandbox 1"
```

---

### Task 4: 更新 sandbox-shared-2.yaml 名称与标签

**Files:**  
- Modify: `examples/python-runtime-sandbox/juicefs-shared/sandbox-shared-2.yaml`

**Step 1: 修改 Sandbox 名与标签**  
与 Task 3 对称：`sandbox-python-juicefs-2` → `juicefs-demo-sandbox-2`；`sandbox: python-juicefs-shared` → `juicefs-demo`；`juicefs/pv-path` → `juicefs-default-juicefs-demo-pvc`；`claimName` → `juicefs-demo-pvc`。

**Step 2: Commit**

```bash
git add examples/python-runtime-sandbox/juicefs-shared/sandbox-shared-2.yaml
git commit -m "examples(juicefs): apply naming convention to sandbox 2"
```

---

### Task 5: 更新 run-test-kind-juicefs.sh 中所有引用

**Files:**  
- Modify: `examples/python-runtime-sandbox/run-test-kind-juicefs.sh`

**Step 1: 替换 PVC 名**  
`pvc/juicefs-shared-pvc` → `pvc/juicefs-demo-pvc`（kubectl wait 与 cleanup 中一并改）。

**Step 2: 替换 Pod 标签选择器**  
`sandbox=python-juicefs-shared` → `sandbox=juicefs-demo`（所有 `-l sandbox=...` 与 wait/delete）。

**Step 3: 确认 cleanup**  
`kubectl delete -f juicefs-pvc.yaml` 删除的即为 `juicefs-demo-pvc`（YAML 内已改）。

**Step 4: 运行脚本验证**

```bash
cd examples/python-runtime-sandbox && ./run-test-kind-juicefs.sh
```

预期：两个 Sandbox Pod 就绪，Pod1 写文件、Pod2 读回一致，输出 "Shared JuiceFS verification OK"。

**Step 5: Commit**

```bash
git add examples/python-runtime-sandbox/run-test-kind-juicefs.sh
git commit -m "examples(juicefs): use juicefs-demo naming in script (PVC and labels)"
```

---

### Task 6: 更新 juicefs-shared/README.md 文档

**Files:**  
- Modify: `examples/python-runtime-sandbox/juicefs-shared/README.md`

**Step 1: 同步命名说明**  
将文档中的 `juicefs-shared-pvc`、`sandbox-python-juicefs-1/2`、`python-juicefs-shared`、`juicefs-default-juicefs-shared-pvc` 替换为规范名称（`juicefs-demo-pvc`、`juicefs-demo-sandbox-1/2`、`juicefs-demo`、`juicefs-default-juicefs-demo-pvc`）。补充：本示例采用前缀 `juicefs-demo`，命名规则见本文档「一、当前 Demo 命名规范」。

**Step 2: 补充多租户命名说明**  
新增小节「多租户命名」：采用一用户一桶/一卷；user-id → 桶 / Secret / StorageClass / PVC → 一卷；卷内每 Pod 一目录，目录名 = Pod 名；Pod 名必须含 user-id（格式 `<prefix>-sandbox-<user-id>-<conversation-id>`）。详见 `docs/plans/2026-03-16-juicefs-demo-naming-convention.md`。

**Step 3: Commit**

```bash
git add examples/python-runtime-sandbox/juicefs-shared/README.md
git commit -m "docs(juicefs): update README to juicefs-demo naming and multi-tenant conventions"
```

---

## 执行方式

1. **Subagent-Driven（本会话）** — 按 Task 1～6 依次执行，每步完成后做一次 code review，再进入下一步。  
2. **Parallel Session（新会话）** — 在新会话中打开本仓库（或 worktree），使用 executing-plans 技能按任务批次执行并设置检查点。

请选择：1 或 2。
