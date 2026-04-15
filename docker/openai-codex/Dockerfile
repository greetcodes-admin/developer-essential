FROM node:20-bookworm

# Base shell, editor, archive, and Codex sandbox tools.
RUN apt-get update && apt-get install -y --no-install-recommends bash-completion bubblewrap ca-certificates file less nano patch procps sudo tree unzip vim zip && rm -rf /var/lib/apt/lists/*

# Network, Git, SSH, search, JSON, and troubleshooting tools.
RUN apt-get update && apt-get install -y --no-install-recommends curl dnsutils git gnupg iputils-ping jq lsof netcat-openbsd openssh-client ripgrep rsync telnet wget && rm -rf /var/lib/apt/lists/*

# PHP CLI, Composer, and common PHP extensions for web app development.
RUN apt-get update && apt-get install -y --no-install-recommends composer php-cli php-bcmath php-curl php-gd php-intl php-mbstring php-mysql php-soap php-sqlite3 php-xml php-zip && rm -rf /var/lib/apt/lists/*

# MySQL and PostgreSQL command-line database clients.
RUN apt-get update && apt-get install -y --no-install-recommends default-mysql-client postgresql-client && rm -rf /var/lib/apt/lists/*

# Build tools and Python runtime for native dependencies and scripts.
RUN apt-get update && apt-get install -y --no-install-recommends build-essential python3 python3-pip && rm -rf /var/lib/apt/lists/*

# PDF read/write and manipulation tools.
RUN apt-get update && apt-get install -y --no-install-recommends ghostscript img2pdf pdftk-java poppler-utils qpdf && rm -rf /var/lib/apt/lists/*

# Image read/write, metadata, OCR, and media tools.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg imagemagick libimage-exiftool-perl tesseract-ocr tesseract-ocr-eng && rm -rf /var/lib/apt/lists/*

# ImageMagick 6 compatibility wrapper for the ImageMagick 7 `magick` CLI.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'case "$1" in' \
    '  animate|compare|composite|conjure|convert|display|identify|import|mogrify|montage|stream)' \
    '    cmd="$1"; shift; exec "$cmd" "$@" ;;' \
    '  *)' \
    '    exec convert "$@" ;;' \
    'esac' \
    > /usr/local/bin/magick \
    && chmod +x /usr/local/bin/magick

# Excel and spreadsheet read/write tools.
RUN apt-get update && apt-get install -y --no-install-recommends gnumeric libreoffice libreoffice-calc python3-odf python3-openpyxl python3-xlrd python3-xlsxwriter && rm -rf /var/lib/apt/lists/*

# Google Chrome browser for browser-based checks and automation.
RUN install -d -m 0755 /etc/apt/keyrings \
    && wget -qO- https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-linux-signing-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-linux-signing-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# OpenAI Codex CLI.
RUN npm install -g @openai/codex

# pnpm package manager for Node projects.
RUN npm install -g pnpm

WORKDIR /workspace

CMD ["bash"]
