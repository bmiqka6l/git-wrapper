ARG BASE_IMAGE=alpine:latest
FROM ${BASE_IMAGE}

# 接收 Action 传来的参数
ARG ORIGINAL_ENTRYPOINT=""
ENV GW_ORIGINAL_ENTRYPOINT=$ORIGINAL_ENTRYPOINT

ARG ORIGINAL_CMD=""
ENV GW_ORIGINAL_CMD=$ORIGINAL_CMD

# 强制切回 Root 安装依赖 (防止 Permission Denied)
USER root

# 智能安装 Git (兼容 Alpine/Debian/CentOS)
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
        echo "Error: Unsupported package manager."; \
        exit 1; \
    fi

COPY git-wrapper.sh /usr/local/bin/git-wrapper.sh
RUN chmod +x /usr/local/bin/git-wrapper.sh

ENTRYPOINT ["/usr/local/bin/git-wrapper.sh"]
