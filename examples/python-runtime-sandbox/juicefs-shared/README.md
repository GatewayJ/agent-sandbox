# JuiceFS 存储示例（同一卷内每 Pod 一目录）

本目录包含在 Kind 集群中部署 **MinIO + Redis + JuiceFS CSI**，并让两个 Sandbox Pod 挂载同一 PVC、**卷内每 Pod 占用一个子目录**（子目录名 = user-id-conv-id）的完整配置。

## 架构

- **MinIO**：对象存储后端（JuiceFS 的 block 存储）；Pod 内 sidecar 在 MinIO 就绪后动态创建 bucket `juicefs`，无需单独 Job
- **Redis**：元数据引擎（JuiceFS 的 metadata）
- **JuiceFS CSI Driver**：提供 `ReadWriteMany` 的 PVC；StorageClass 使用 **pathPattern**，PV 在 JuiceFS 内子目录名为 `juicefs-<namespace>-<pvc-name>`（本示例为 `juicefs-default-juicefs-demo-pvc`）
- **两个 Sandbox Pod**：挂载同一 `juicefs-demo-pvc`，通过 **subPath** 各占卷内一个子目录（两级）：Demo 中 user-id=user-1，会话 conv-1/conv-2，子目录为 `user-1/conv-1`、`user-1/conv-2`；Pod 名含 user-id（`juicefs-demo-sandbox-user-1-conv-1`、`juicefs-demo-sandbox-user-1-conv-2`）

## 一键部署

在仓库根目录或本示例目录的上一级执行：

```bash
# 从 examples/python-runtime-sandbox 运行
./run-test-kind-juicefs.sh
```

脚本会依次：

1. 构建并部署 agent-sandbox 到 Kind
2. 构建并加载 `sandbox-runtime` 镜像
3. 创建命名空间 `juicefs-infra`，部署 MinIO（含 bucket 动态创建 sidecar）、Redis
4. 部署 JuiceFS CSI Driver（来自官方 manifest URL）
5. 创建 Secret、StorageClass、PVC
6. 部署两个 Sandbox（`juicefs-demo-sandbox-user-1-conv-1`、`juicefs-demo-sandbox-user-1-conv-2`）
7. 校验：每个 Pod 在各自子目录（user-1/conv-1、user-1/conv-2）内写读

## 文件说明

| 文件 | 说明 |
|------|------|
| `namespace.yaml` | 命名空间 `juicefs-infra` |
| `minio.yaml` | MinIO Deployment + Service（含 bucket-init sidecar 动态创建 bucket） |
| `redis.yaml` | Redis Deployment + Service（元数据） |
| `juicefs-secret.yaml` | JuiceFS CSI 用 Secret（kube-system） |
| `juicefs-storageclass.yaml` | StorageClass `juicefs-sc`（含 pathPattern：`juicefs-${.pvc.namespace}-${.pvc.name}`） |
| `juicefs-pvc.yaml` | 共享 PVC（ReadWriteMany，10Pi） |
| `sandbox-shared-1.yaml` | Sandbox Pod 1，user-id=user-1、conv-id=conv-1，subPath `user-1/conv-1` 挂到 `/shared` |
| `sandbox-shared-2.yaml` | Sandbox Pod 2，user-id=user-1、conv-id=conv-2，subPath `user-1/conv-2` 挂到 `/shared` |

本示例采用前缀 `juicefs-demo`，PVC 与 Sandbox 命名规则见 `docs/plans/2026-03-16-juicefs-demo-naming-convention.md` 第一节。

## 示例与生产环境（注意事项）

本示例**仅用于本地/CI 演示与验证**，不可直接用于生产：

- **敏感信息**：`minio.yaml`、`juicefs-secret.yaml` 中使用固定账号/密码（如 `minioadmin`）。生产环境必须使用独立 Secret 或外部机密管理，且不得将真实凭证提交到仓库。
- **CSI Driver URL**：脚本从 JuiceFS CSI 官方 `master` 的 manifest URL 拉取，依赖网络且 master 可能变更。生产或需稳定版本时，请改为具体 release tag 的 URL（如 `https://raw.githubusercontent.com/juicedata/juicefs-csi-driver/v1.x.x/deploy/k8s.yaml`）。
- **Redis**：示例中 Redis 未配置持久化（无 PVC），重启后元数据丢失。生产环境应为 Redis 配置持久化存储。
- **镜像 tag**：示例中 MinIO/Redis 等使用 `latest` 或大版本 tag，不同时间部署结果可能不一致。生产或需可重复部署时，建议使用具体镜像 tag（如 `minio/minio:RELEASE.2024-xx-xx`、`redis:7.2-alpine`）。

## 路径与标签

- **PV 子目录（pathPattern）**：动态生成的 PV 在 JuiceFS 内对应子目录名由 StorageClass 的 pathPattern 决定，期望为 `juicefs-<namespace>-<pvc-name>`（如 `juicefs-default-juicefs-demo-pvc`）。pathPattern **仅在新创建 PV 时生效**；若未生效（如 CSI 版本或创建顺序原因），则使用默认名 `pvc-<PVC_UID>`。集群外挂载时根目录下看到的即是该 PV 子目录（可能是上述二者之一）。
- **Pod 标签**：`user-id: user-1`、`conv-id: conv-1`/`conv-2`、`juicefs/bucket`、`juicefs/pv-path`。卷内子目录为两级 user-id/conv-id，即 `user-1/conv-1`、`user-1/conv-2`。

## 多租户命名

扩展为多租户时采用：**一用户一桶/一卷**。对应关系：user-id → MinIO 桶 / Secret（`juicefs-secret-<user-id>`）/ StorageClass（`juicefs-sc-<user-id>`）/ PVC（`juicefs-demo-pvc-<user-id>`）→ 一个 JuiceFS 卷；该用户所有 Pod 挂载该 PVC，卷内每个 Pod 占用一个子目录，**目录名 = Pod 名**；**Pod 名必须含 user-id**，格式 `<prefix>-sandbox-<user-id>-<conversation-id>`（如 `juicefs-demo-sandbox-user123-conv-abc`）。详见 `docs/plans/2026-03-16-juicefs-demo-naming-convention.md`。

## 参考

- [JuiceFS 在 K3s 上使用](https://juicefs.com/docs/zh/community/juicefs_on_k3s)
- [JuiceFS CSI 创建和使用 PV - 动态配置](https://juicefs.com/docs/zh/csi/guide/pv#dynamic-provisioning)
- [高级功能与配置 - pathPattern](https://juicefs.com/docs/zh/csi/guide/configurations/#using-path-pattern)
- [JuiceFS CSI Driver](https://github.com/juicedata/juicefs-csi-driver)
