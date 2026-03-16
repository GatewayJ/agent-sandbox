# slim 体积适中；额外装少量常用工具（curl/ps/less）便于调试，不加 full bookworm
FROM python:3.11-bookworm

WORKDIR /app

# 仅安装常用调试工具，--no-install-recommends 控制体积
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl procps less \
    && rm -rf /var/lib/apt/lists/*

# Installation of dependencies for python runtime sandbox.
COPY requirements.txt .

RUN pip install --no-cache-dir --require-hashes -r requirements.txt

COPY main.py .

# Change ownership of the /app directory to the non-root user 1000.
RUN chown -R 1000:1000 /app
USER 1000

# Expose the port that the Uvicorn server will run on.
# This must match the port in the CMD instruction below.
EXPOSE 8888

# The command to run when the container starts.
# This starts the Uvicorn server, making our API available.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8888", "--log-level", "trace"]
