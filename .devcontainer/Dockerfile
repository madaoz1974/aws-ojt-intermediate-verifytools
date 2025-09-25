FROM ubuntu:22.04

# 基本的なパッケージとタイムゾーンの設定
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Tokyo

# システムの更新と基本ツールのインストール
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    unzip \
    git \
    jq \
    vim \
    nano \
    ca-certificates \
    gnupg \
    lsb-release \
    python3 \
    python3-pip \
    postgresql-client \
    dnsutils \
    iputils-ping \
    netcat-traditional \
    telnet \
    tree \
    htop \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ユーザー作成
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# AWS CLI v2のインストール（アーキテクチャ対応）
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        AWS_CLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    fi && \
    curl "$AWS_CLI_URL" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws

# Session Manager Plugin のインストール（アーキテクチャ対応）
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_arm64/session-manager-plugin.deb"; \
    fi && \
    curl "$PLUGIN_URL" -o "session-manager-plugin.deb" && \
    dpkg -i session-manager-plugin.deb && \
    rm session-manager-plugin.deb

# Python パッケージのインストール
RUN pip3 install \
    boto3 \
    psycopg2-binary \
    requests \
    tabulate \
    colorama

# 作業ディレクトリの設定
WORKDIR /workspace

# ユーザーの切り替え
USER $USERNAME

# AWS CLI の設定ディレクトリ作成
RUN mkdir -p /home/$USERNAME/.aws

# bashrcの設定
RUN echo 'alias ll="ls -la"' >> /home/$USERNAME/.bashrc \
    && echo 'alias la="ls -A"' >> /home/$USERNAME/.bashrc \
    && echo 'alias l="ls -CF"' >> /home/$USERNAME/.bashrc \
    && echo 'export PATH=$PATH:/usr/local/bin' >> /home/$USERNAME/.bashrc

SHELL ["/bin/bash", "-c"]