# 基于 openclaw:main-slim，在同一容器内同时跑 openclaw gateway 与 python-sandbox (uvicorn)
# 使用 supervisord 管理两个进程
FROM ghcr.io/openclaw/openclaw:main-slim

# 使用 root 安装系统依赖（基础镜像可能已是 USER node）
USER root

# 安装 Python3、pip、supervisor；保留常用调试工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    supervisor \
    curl \
    procps \
    less \
    net-tools  \
    vim \
    && rm -rf /var/lib/apt/lists/*

# 使用 /app 作为工作目录（若 openclaw 基础镜像把 node 应用放在 /home/node，请把下方改为 WORKDIR /home/node 并相应改 supervisord.conf 中的 directory）
WORKDIR /app

# 安装 python-sandbox 依赖
COPY requirements.txt requirements.in ./
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt

# 加入 python-sandbox 代码、supervisord 配置与 openclaw 默认配置（--bind lan 时 Control UI 需允许 origin）
COPY main.py supervisord.conf openclaw.default.json ./

# 若基础镜像以 node 用户运行，可切回以匹配 Pod 的 runAsUser: 1000
# 若基础镜像无 node 用户则注释下一行
USER 1000

# 暴露 gateway 与 sandbox 端口
EXPOSE 18789 18790 8888

# 若挂载的 .openclaw 下尚无 openclaw.json 则写入默认配置；挂载 NAS 后已有文件时不会覆盖。
# 需用镜像内默认配置覆盖 NAS 上已有配置时，在 Pod 中设置 env: OPENCLAW_FORCE_DEFAULT_CONFIG=1
CMD ["sh", "-c", "mkdir -p /home/node/.openclaw && ( [ \"$OPENCLAW_FORCE_DEFAULT_CONFIG\" = 1 ] || [ \"$OPENCLAW_FORCE_DEFAULT_CONFIG\" = true ] || [ ! -f /home/node/.openclaw/openclaw.json ] ) && cp /app/openclaw.default.json /home/node/.openclaw/openclaw.json; exec supervisord -n -c ./supervisord.conf"]
