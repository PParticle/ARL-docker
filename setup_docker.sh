#!/bin/bash

set -euo pipefail

DOCKER_MIRRORS=(
    "https://docker.m.daocloud.io"
    "https://docker.1panel.live"
    "https://dockerhub.timeweb.cloud"
)

ARL_IMAGE="honmashironeko/arl-docker-all:latest"
ARL_IMAGE_MIRROR="swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/honmashironeko/arl-docker-all:latest"

echo "Docker 镜像作者：本间白猫"
echo "公众号：樱花庄的本间白猫"
echo "博客：https://y.shironekosan.cn"
echo "Github：https://github.com/honmashironeko/ARL-docker"
echo "感谢您使用本脚本，请仔细阅读脚本内容，根据提示进行操作。"

echo -n "按回车键继续..."
read -n 1 -s
clear

configure_docker_registry_mirrors() {
    local config_file="/etc/docker/daemon.json"
    local config_dir
    config_dir="$(dirname "$config_file")"

    mkdir -p "$config_dir"
    if [ -f "$config_file" ] && [ ! -f "${config_file}.bak" ]; then
        cp "$config_file" "${config_file}.bak"
    fi

    cat >"$config_file" <<EOF
{
  "registry-mirrors": [
    "${DOCKER_MIRRORS[0]}",
    "${DOCKER_MIRRORS[1]}",
    "${DOCKER_MIRRORS[2]}"
  ]
}
EOF

    systemctl daemon-reload
    systemctl restart docker
}

install_docker() {
    if command -v yum >/dev/null 2>&1; then
        echo "正在使用 yum 安装 Docker..."
        yum install -y docker
        setenforce 0 || true
    elif command -v apt-get >/dev/null 2>&1; then
        echo "正在使用 apt 安装 Docker.io..."
        apt-get update
        apt-get install -y docker.io
    else
        echo "无法确定包管理器。请手动安装 Docker。"
        exit 1
    fi

    echo "正在配置 Docker 镜像加速..."
    configure_docker_registry_mirrors

    echo "正在启动 Docker 服务..."
    systemctl enable docker >/dev/null 2>&1 || true
    if ! systemctl start docker; then
        echo "启动 Docker 服务失败。"
        echo "请手动检查 Docker 服务是否成功安装"
        exit 1
    fi
    echo "Docker 服务启动成功。"

    cp docker-compose /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

ensure_docker_ready() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "未检测到 docker 命令。"
        exit 1
    fi

    if ! command -v docker-compose >/dev/null 2>&1; then
        cp docker-compose /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    if [ ! -f /etc/docker/daemon.json ]; then
        echo "未检测到 Docker 镜像加速配置，正在补充配置..."
        configure_docker_registry_mirrors
    fi

    if ! systemctl is-active --quiet docker; then
        systemctl start docker
    fi
}

pull_image_with_fallback() {
    local primary_image="$1"
    local fallback_image="${2:-}"

    if docker pull "$primary_image"; then
        return 0
    fi

    if [ -n "$fallback_image" ]; then
        echo "主镜像拉取失败，尝试备用镜像源：$fallback_image"
        docker pull "$fallback_image"
        docker tag "$fallback_image" "$primary_image"
        return 0
    fi

    return 1
}

pull_required_images() {
    echo "开始预拉取部署所需镜像..."
    pull_image_with_fallback "mongo:4.0.27"
    pull_image_with_fallback "rabbitmq:3.8.19-management-alpine"
    pull_image_with_fallback "$ARL_IMAGE" "$ARL_IMAGE_MIRROR"
}

wait_for_arl() {
    local attempts=60
    local interval=2
    local i

    echo "等待 ARL Web 服务启动..."
    for ((i = 1; i <= attempts; i++)); do
        if curl -ksI --max-time 5 https://127.0.0.1:5003 >/dev/null 2>&1; then
            echo "ARL Web 服务已启动。"
            return 0
        fi
        sleep "$interval"
    done

    echo "ARL Web 服务启动超时。"
    return 1
}

import_fingerprints() {
    if [ ! -f ./ARL-Finger-ADD.py ]; then
        echo "未找到 ARL-Finger-ADD.py，跳过指纹导入。"
        return 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        if command -v yum >/dev/null 2>&1; then
            yum install -y python3 python3-pip
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update
            apt-get install -y python3 python3-pip
        else
            echo "无法确定包管理器。请手动安装 Python3。"
            return 1
        fi
    fi

    python3 ./ARL-Finger-ADD.py https://127.0.0.1:5003/ admin honmashironeko
}

get_access_ip() {
    local public_ip=""
    public_ip="$(curl -s --max-time 5 ipinfo.io/ip || true)"
    if [ -n "$public_ip" ]; then
        echo "$public_ip"
        return 0
    fi

    hostname -I 2>/dev/null | awk '{print $1}'
}

echo "请选择是否需要更换 yum 或 apt 下载源："
echo "1) 不进行更换，使用默认下载源"
echo "2) 运行替换脚本，更换下载源"
read -p "请输入选项（1-2）[默认1]: " sz
sz=${sz:-1}

case "$sz" in
    1)
        echo "不进行更换，使用默认下载源"
        ;;
    2)
        bash main.sh
        ;;
    *)
        echo "无效的输入，脚本将退出。"
        exit 1
        ;;
esac

clear
echo "如果您已安装过 Docker 服务，请输入y，否则输入n"
read -p "是否进入仅执行安装程序：[y/N]" iz
iz=${iz:-n}
case "$iz" in
    y|Y)
        echo "仅安装 ARL"
        ensure_docker_ready
        ;;
    n|N)
        install_docker
        ;;
    *)
        echo "无效的输入，脚本将退出。"
        exit 1
        ;;
esac

echo "开始部署"
pull_required_images
docker volume create --name=arl_db >/dev/null 2>&1 || true

if ! docker-compose up -d; then
    echo "docker-compose 启动失败，请执行 docker-compose logs 查看详情。"
    exit 1
fi

wait_for_arl

read -p "请确认是否添加指纹：[y/N]" yn
yn=${yn:-N}
case "$yn" in
    y|Y)
        import_fingerprints || {
            echo "指纹导入失败，请手动执行：python3 ARL-Finger-ADD.py https://127.0.0.1:5003/ admin honmashironeko"
            exit 1
        }
        ;;
    n|N)
        echo "跳过指纹导入。"
        ;;
    *)
        echo "无效的输入，默认跳过指纹导入。"
        ;;
esac

echo "已完成 ARL 部署，感谢您的使用。"
echo "Github：https://github.com/honmashironeko/ARL-docker"
echo "博客：https://y.shironekosan.cn"
echo "公众号：樱花庄的本间白猫"

CURRENT_IP="$(get_access_ip)"
URL="https://${CURRENT_IP}:5003"
echo "ARL URL: $URL"
