# JuiceFS 共享存储示例（两 Pod 共享同一 PVC）

本目录包含在 Kind 集群中部署 **MinIO + Redis + JuiceFS CSI**，并让两个 Sandbox Pod 通过同一 PVC 共享文件的完整配置。

## 架构

- **MinIO**：对象存储后端（JuiceFS 的 block 存储）；Pod 内 sidecar 在 MinIO 就绪后动态创建 bucket `juicefs`，无需单独 Job
- **Redis**：元数据引擎（JuiceFS 的 metadata）
- **JuiceFS CSI Driver**：提供 `ReadWriteMany` 的 PVC；StorageClass 使用 **pathPattern**，PV 在 JuiceFS 内子目录名为 `juicefs-<namespace>-<pvc-name>`（如 `juicefs-default-juicefs-shared-pvc`），便于区分 IO/挂载路径
- **两个 Sandbox Pod**：挂载同一 `juicefs-shared-pvc`，在 `/shared` 下读写共享文件；Pod 带标签 `juicefs/bucket`、`juicefs/pv-path` 与 pathPattern 对应，便于从 Pod 反查 bucket 与挂载路径

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
6. 部署两个 Sandbox（`sandbox-python-juicefs-1`、`sandbox-python-juicefs-2`）
7. 校验共享：在 Pod1 写文件，在 Pod2 读回

## 文件说明

| 文件 | 说明 |
|------|------|
| `namespace.yaml` | 命名空间 `juicefs-infra` |
| `minio.yaml` | MinIO Deployment + Service（含 bucket-init sidecar 动态创建 bucket） |
| `redis.yaml` | Redis Deployment + Service（元数据） |
| `juicefs-secret.yaml` | JuiceFS CSI 用 Secret（kube-system） |
| `juicefs-storageclass.yaml` | StorageClass `juicefs-sc`（含 pathPattern：`juicefs-${.pvc.namespace}-${.pvc.name}`） |
| `juicefs-pvc.yaml` | 共享 PVC（ReadWriteMany，10Pi） |
| `sandbox-shared-1.yaml` | Sandbox Pod 1，挂载 `juicefs-shared-pvc` 到 `/shared` |
| `sandbox-shared-2.yaml` | Sandbox Pod 2，同上 |

## 示例与生产环境（注意事项）

本示例**仅用于本地/CI 演示与验证**，不可直接用于生产：

- **敏感信息**：`minio.yaml`、`juicefs-secret.yaml` 中使用固定账号/密码（如 `minioadmin`）。生产环境必须使用独立 Secret 或外部机密管理，且不得将真实凭证提交到仓库。
- **CSI Driver URL**：脚本从 JuiceFS CSI 官方 `master` 的 manifest URL 拉取，依赖网络且 master 可能变更。生产或需稳定版本时，请改为具体 release tag 的 URL（如 `https://raw.githubusercontent.com/juicedata/juicefs-csi-driver/v1.x.x/deploy/k8s.yaml`）。
- **Redis**：示例中 Redis 未配置持久化（无 PVC），重启后元数据丢失。生产环境应为 Redis 配置持久化存储。
- **镜像 tag**：示例中 MinIO/Redis 等使用 `latest` 或大版本 tag，不同时间部署结果可能不一致。生产或需可重复部署时，建议使用具体镜像 tag（如 `minio/minio:RELEASE.2024-xx-xx`、`redis:7.2-alpine`）。

## 路径与标签

- **PV 子目录（pathPattern）**：动态生成的 PV 在 JuiceFS 文件系统内对应子目录名为 `juicefs-<namespace>-<pvc-name>`，与 MinIO bucket 名 `juicefs` 一致，IO 与挂载路径清晰可辨。
- **Pod 标签**：两个 Sandbox 的 podTemplate 带有 `juicefs/bucket: juicefs`、`juicefs/pv-path: juicefs-default-juicefs-shared-pvc`，便于通过 `kubectl get pods -L juicefs/bucket,juicefs/pv-path` 从 Pod 反查使用的 bucket 与 PV 路径。

## 参考

- [JuiceFS 在 K3s 上使用](https://juicefs.com/docs/zh/community/juicefs_on_k3s)
- [JuiceFS CSI 创建和使用 PV - 动态配置](https://juicefs.com/docs/zh/csi/guide/pv#dynamic-provisioning)
- [高级功能与配置 - pathPattern](https://juicefs.com/docs/zh/csi/guide/configurations/#using-path-pattern)
- [JuiceFS CSI Driver](https://github.com/juicedata/juicefs-csi-driver)
