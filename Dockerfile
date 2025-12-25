# 接收基础镜像参数
ARG BASE_IMAGE=alpine:latest
FROM ${BASE_IMAGE}

# 接收原始 Entrypoint 参数 (由 Action 探测后注入)
ARG ORIGINAL_ENTRYPOINT=""

# 将其固化为运行时环境变量 (供 wrapper 脚本使用)
ENV GW_ORIGINAL_ENTRYPOINT=$ORIGINAL_ENTRYPOINT

# !!! 关键：切换到 Root 以确保能安装 Git !!!
USER root

# 智能安装 Git (兼容 Alpine/Debian/RHEL 系)
RUN set -e; \
    if command -v apk > /dev/null; then \
        apk add --no-cache git bash ca-certificates openssh-client; \
    elif command -v apt-get > /dev/null; then \
        apt-get update && apt-get install -y git bash ca-certificates openssh-client && rm -rf /var/lib/apt/lists/*; \
    elif command -v microdnf > /dev/null; then \
        microdnf install -y git bash ca-certificates openssh-clients; \
    elif command -v yum > /dev/null; then \
        yum install -y git bash ca-certificates openssh-clients; \
    else \
        echo "Error: Base image has no supported package manager or is scratch/distroless."; \
        exit 1; \
    fi

# 注入 Wrapper
COPY git-wrapper.sh /usr/local/bin/git-wrapper.sh
RUN chmod +x /usr/local/bin/git-wrapper.sh

# 设置新入口
ENTRYPOINT ["/usr/local/bin/git-wrapper.sh"]

# 注意：不指定 CMD，自动继承原镜像 CMD