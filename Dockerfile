FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Use a mainland-China mirror so dependency installation remains reliable when
# Docker is running on a domestic network.
RUN sed -i \
      -e 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
      -e 's|http://security.ubuntu.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' \
      -e 's|http://ports.ubuntu.com/ubuntu-ports/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/|g' \
      /etc/apt/sources.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk \
    gettext git libncurses-dev libssl-dev python3 python3-setuptools rsync \
    swig unzip zlib1g-dev file wget libelf-dev ccache qemu-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/openwrt
CMD ["sleep", "infinity"]
