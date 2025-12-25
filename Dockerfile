ARG BASE_IMAGE=alpine:latest
FROM ${BASE_IMAGE}

# 1. 接收 Entrypoint
ARG ORIGINAL_ENTRYPOINT=""
ENV GW_ORIGINAL_ENTRYPOINT=$ORIGINAL_ENTRYPOINT

# 2. 接收 CMD
ARG ORIGINAL_CMD=""
ENV GW_ORIGINAL_CMD=$ORIGINAL_CMD

# 3. 接收 WorkDir
ARG ORIGINAL_WORKDIR="/"
ENV GW_ORIGINAL_WORKDIR=$ORIGINAL_WORKDIR

# 强制切回 Root 以便安装 Git
USER root

# 智能安装依赖 (兼容 Alpine/Debian/RHEL)
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
        echo "Error: Unsupported package manager (distroless?)."; \
        exit 1; \
    fi

COPY git-wrapper.sh /usr/local/bin/git-wrapper.sh
RUN chmod +x /usr/local/bin/git-wrapper.sh

ENTRYPOINT ["/usr/local/bin/git-wrapper.sh"]
