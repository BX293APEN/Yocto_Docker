# =============================================================================
# Dockerfile  ―  Yocto ビルド環境
# Ubuntu 22.04 LTS ベース (Yocto公式推奨)
# https://docs.yoctoproject.org/ref-manual/system-requirements.html
# =============================================================================

FROM ubuntu:22.04

ARG WS
ARG ENTRY_DIR
ARG ENTRY_POINT

ENV DEBIAN_FRONTEND=noninteractive

# ── Yocto 公式必須依存パッケージ ─────────────────────────────────────────
# https://docs.yoctoproject.org/brief-yoctoprojectqs/index.html
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y \
        gawk \
        wget \
        git \
        diffstat \
        unzip \
        texinfo \
        gcc \
        build-essential \
        chrpath \
        socat \
        cpio \
        python3 \
        python3-pip \
        python3-pexpect \
        xz-utils \
        debianutils \
        iputils-ping \
        python3-git \
        python3-jinja2 \
        python3-subunit \
        zstd \
        liblz4-tool \
        file \
        locales \
        libacl1 \
        lz4 \
        # イメージ操作ツール
        parted \
        dosfstools \
        e2fsprogs \
        util-linux \
        qemu-utils \
        # ネットワーク
        curl \
        ca-certificates \
        rsync \
        # その他ユーティリティ
        sudo \
        bash \
        nano \
        vim \
        tar \
        gzip \
        bzip2 && \
    # ロケール設定
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 && \
    # ビルドユーザー作成(Yoctoはrootでのビルドを禁止している)
    useradd -m -s /bin/bash -G sudo yocto && \
    echo "yocto ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    # ワークスペース作成
    /${ENTRY_DIR} && \
    chown -R yocto:yocto /${WS} /${ENTRY_DIR}

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

COPY ${ENTRY_POINT} /${ENTRY_DIR}/${ENTRY_POINT}
RUN chmod +x /${ENTRY_DIR}/${ENTRY_POINT} && \
    chown yocto:yocto /${ENTRY_DIR}/${ENTRY_POINT}

WORKDIR /${WS}
USER yocto
