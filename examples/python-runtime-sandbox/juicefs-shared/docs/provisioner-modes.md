# csi.juicefs.com 内两种 Provision 路径分析

StorageClass 的 `provisioner: csi.juicefs.com` 只表示「由 JuiceFS CSI 驱动负责动态创建 PV」。驱动内部有**两条不同的代码路径**来完成这件事，取决于部署方式。

---

## 对比总览

| 项目 | 方式一：标准 CSI Provisioner（默认） | 方式二：JuiceFS 内建 Provisioner |
|------|--------------------------------------|----------------------------------|
| **触发者** | 集群中的 **csi-provisioner** sidecar 容器 | JuiceFS 进程内的 **provisionerService**（需 `--provisioner=true`） |
| **调用的接口** | CSI gRPC **CreateVolume** | 内部 **Provision()**（非 CSI 标准，为 sig-storage-lib-external-provisioner 接口） |
| **源码位置** | `pkg/driver/controller.go` → `CreateVolume()` | `pkg/driver/provisioner.go` → `Provision()` |
| **subPath 来源** | 固定为 `req.Name`（即 PV 名，通常为 `pvc-<UUID>`） | StorageClass parameters 经 **pathPattern** 模板解析得到 |
| **pathPattern** | **不解析**，仅打日志提示启用内建 provisioner | **解析**（如 `${.pvc.namespace}`、`${.pvc.name}` 等） |
| **部署形态** | Controller Pod 内包含 **csi-provisioner** sidecar（4 个容器） | 无 csi-provisioner sidecar，juicefs-plugin 启动参数带 `--provisioner=true`（3 个容器） |

---

## 方式一：CreateVolume 路径（默认部署）

**流程：**

1. 用户创建 PVC（`storageClassName: juicefs-sc`）。
2. **csi-provisioner** sidecar 监听到 PVC，向 JuiceFS CSI 发起 **CreateVolume** gRPC 请求，请求里带 StorageClass 的 `parameters`（含 pathPattern 原始字符串）。
3. **controller.go** 中 `CreateVolume()` 被调用：
   - `subPath := req.Name`（PV 名由 K8s 生成，一般为 `pvc-<PVC_UID>`）；
   - 若 `req.Parameters["pathPattern"] != ""` 仅打日志：*"volume uses pathPattern, please enable provisioner in CSI Controller, not works in default mode."*；
   - 不会用 pathPattern 改写 subPath。
4. 返回的 Volume 的 subPath 固定为 PV 名，故 JuiceFS 内目录名为 **pvc-&lt;UUID&gt;**。

**结论：** 默认部署下，pathPattern 不生效，目录名始终是 `pvc-<UUID>`。

---

## 方式二：内建 Provision() 路径

**流程：**

1. juicefs-csi-controller 启动时带上 **`--provisioner=true`**，且**不部署** csi-provisioner sidecar。
2. 驱动内 **provisionerService.Run()** 启动，使用 sig-storage-lib-external-provisioner 库**直接监听 PVC**。
3. 用户创建 PVC 后，由 **provisioner.go** 的 `Provision()` 处理：
   - 从 `options.StorageClass.Parameters` 读取各参数；
   - 对**非** `csi.storage.k8s.io/*` 的 key（如 pathPattern）做 **pvMeta.StringParser()**，将 `${.pvc.namespace}`、`${.pvc.name}` 等替换为当前 PVC 的 namespace/name；
   - `subPath := pvName`，若 `scParams["pathPattern"] != ""` 则 `subPath = scParams["pathPattern"]`（已解析后的字符串）；
   - 创建 PV 时在 VolumeAttributes 里写入该 subPath。
4. JuiceFS 内目录名即为 pathPattern 解析结果，例如 **juicefs-default-juicefs-demo-pvc**。

**结论：** 只有启用内建 provisioner，pathPattern 才会生效。

---

## 为何存在两条路径？

- **CreateVolume** 是 **CSI 标准接口**：由任意符合 CSI 的 sidecar（如社区 csi-provisioner）调用，便于与 K8s 生态一致，但接口只传「参数键值」，不传 PVC 元数据，驱动端无法在 CreateVolume 里做「按 PVC 名字/namespace 替换模板」。
- **内建 Provision()** 使用 **external-provisioner 库**：在驱动进程内直接拿 K8s API 的 PVC/Node 对象，可访问 namespace、name、labels 等，因此能实现 pathPattern 等依赖 PVC 元数据的功能。

因此 pathPattern、按 PVC 定制 mountOptions 等能力，只在「内建 provisioner」路径下实现；默认的「csi-provisioner + CreateVolume」路径只做最基础的按 PV 名创建目录。

---

## 本示例中的用法

脚本 `run-test-kind-juicefs.sh` 在部署完官方 `k8s.yaml` 后：

1. 对 **juicefs-csi-controller** StatefulSet 给 juicefs-plugin 容器增加 `--provisioner=true`；
2. 删除 **csi-provisioner** 容器；
3. 再创建 StorageClass 与 PVC。

这样新 PVC 会走**内建 Provision()**，pathPattern 生效，JuiceFS 根目录下可见 **juicefs-default-juicefs-demo-pvc** 而非 `pvc-<UUID>`。
