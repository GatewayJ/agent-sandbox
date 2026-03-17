# NAS 挂载路径权限控制（NFS / JuiceFS）

NFS 与 JuiceFS 两种脚本下，挂载的 NAS 路径权限可通过 **Pod securityContext** 与 **服务端配置** 配合控制。

## 1. 通用：Pod securityContext

在 Sandbox 的 `podTemplate.spec` 下增加 `securityContext`，可统一控制容器进程与卷的访问身份：

```yaml
spec:
  podTemplate:
    spec:
      securityContext:
        runAsUser: 1000          # 容器内进程 UID，创建的文件属主
        runAsGroup: 3000         # 进程 GID
        fsGroup: 3000            # 挂载卷的补充 GID，部分驱动会 chown 卷根
      containers:
        - name: python-sandbox
          # ...
```

- **runAsUser / runAsGroup**：容器内进程以该 UID/GID 运行，在 NAS 上创建的文件会带上该属主/属组（在支持 POSIX 语义的存储上，如 JuiceFS）。
- **fsGroup**：Kubernetes 会对**部分**卷类型在挂载时做权限变更（例如把卷根 chown 到 fsGroup），使组内成员可写。**NFS 通常不会**对已有目录做递归 chown，仅对新挂载的“空卷”或部分实现有效；JuiceFS 行为更接近本地盘，fsGroup 通常有效。

要让多个 Pod（如 hub、shared-1、shared-2）**互相读写同一目录**，应让它们使用**相同的 runAsUser/runAsGroup（以及可选的 fsGroup）**，这样在 NAS 上看到的 UID/GID 一致，不会出现“别人创建的文件我写不了”的问题。

---

## 2. NFS 权限控制

### 2.1 特性与限制

- NFS 服务端按 **UID/GID** 做权限校验，不认用户名。
- **fsGroup 对 NFS 卷通常不生效**：Kubelet 不会对 NFS 已有目录做递归 chown，所以仅设 fsGroup 往往无法让多 Pod 共享写。
- 可行做法：**所有挂载该 NFS 的 Pod 使用同一 runAsUser/runAsGroup**，在服务端看来就是同一用户，自然可互相读写。

### 2.2 推荐做法

1. **在 Pod 上统一身份**（推荐）

   在 NFS 相关 Sandbox（如 `sandbox-csg-hub-server`、`sandbox-shared-1`、`sandbox-shared-2`）的 `podTemplate.spec` 里设相同 `securityContext`：

   ```yaml
   securityContext:
     runAsUser: 1000
     runAsGroup: 3000
     # fsGroup 对 NFS 多数情况无效，可省略或与 runAsGroup 一致
     fsGroup: 3000
   ```

   这样所有 Pod 在 NFS 上创建的文件都是 1000:3000，彼此可读写。

2. **在 NFS 服务端做“匿名”映射**（可选）

   若使用自建 NFS 服务（如 `itsthenetwork/nfs-server-alpine`），可在 export 时使用 **all_squash + anonuid/anongid**，把所有客户端映射为同一 UID/GID，再让 Pod 的 runAsUser/runAsGroup 与 anonuid/anongid 一致，效果同上。具体取决于 NFS 服务实现与配置方式（例如 `/etc/exports` 或容器环境变量）。

3. **不在 K8s 里依赖 fsGroup**

   不要依赖 NFS 卷上的 fsGroup 做递归 chown；若需统一权限，以 runAsUser/runAsGroup 为准。

---

## 3. JuiceFS 权限控制

### 3.1 特性

- JuiceFS 在元数据里保存 **Linux UID/GID**，行为接近本地文件系统。
- **runAsUser / runAsGroup / fsGroup** 都会在挂载和创建文件时生效，Kubelet 对 JuiceFS 卷的 fsGroup 处理也较一致。

### 3.2 推荐做法

与 NFS 类似：**所有需要共享同一目录的 Pod 使用相同的 securityContext**：

```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 3000
  fsGroup: 3000
```

这样 hub（挂卷根）与 shared-1/shared-2（挂 subPath）在 JuiceFS 上看到的属主/属组一致，可互相读写。

---

## 4. 在现有示例中启用权限控制

在以下文件中为 `spec.podTemplate.spec` 增加相同的 `securityContext` 即可（数值按你环境统一即可，例如 1000:3000）：

- **NFS**：`nfs-shared/sandbox-csg-hub-server.yaml`、`sandbox-shared-1.yaml`、`sandbox-shared-2.yaml`
- **JuiceFS**：`juicefs-shared/sandbox-csg-hub-server.yaml`、`sandbox-shared-1.yaml`、`sandbox-shared-2.yaml`

示例（以 NFS hub 为例）：

```yaml
spec:
  podTemplate:
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 3000
        fsGroup: 3000
      containers:
        - name: python-sandbox
          # ...
```

三处 Sandbox（hub + shared-1 + shared-2）保持一致，即可在对应 NAS 路径上实现可预期的权限与多 Pod 共享写。
