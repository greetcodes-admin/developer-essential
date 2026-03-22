#!/bin/bash

set -e

# Detect OS
. /etc/os-release
DISTRO_ID=$ID
DISTRO_VERSION_CODENAME=$VERSION_CODENAME
ARCH=$(dpkg --print-architecture)

if [[ "$DISTRO_ID" != "ubuntu" && "$DISTRO_ID" != "debian" ]]; then
  echo "❌ This script supports only Ubuntu or Debian."
  exit 1
fi

echo "Detected OS: $DISTRO_ID $DISTRO_VERSION_CODENAME ($ARCH)"

# Setup variables
BASE_URL="https://download.docker.com/linux/$DISTRO_ID/dists/$DISTRO_VERSION_CODENAME/pool/stable/$ARCH"
DOWNLOAD_DIR="/tmp/docker-debs"
mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

# List of required deb package base names
packages=(
  "containerd.io"
  "docker-ce-cli"
  "docker-ce"
  "docker-buildx-plugin"
  "docker-compose-plugin"
)

# Download latest .deb files for each required package
for pkg in "${packages[@]}"; do
    echo "Searching for: $pkg ..."
    file=$(curl -s "$BASE_URL/" | grep -oP "$pkg.*?_${ARCH}\.deb" | sort -V | tail -n 1)
    if [[ -n "$file" ]]; then
        echo "Downloading: $file"
        curl -LO "$BASE_URL/$file"
    else
        echo "❌ Error: $pkg not found!"
        exit 1
    fi
done

echo "Installing Docker packages..."
sudo dpkg -i ./*.deb || sudo apt -f install -y

echo "Enabling and starting Docker..."
sudo systemctl enable docker
sudo systemctl start docker

echo "✅ Docker installed successfully."


