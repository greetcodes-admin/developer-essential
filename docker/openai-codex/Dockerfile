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

# OpenAI Codex CLI.
RUN npm install -g @openai/codex

# pnpm package manager for Node projects.
RUN npm install -g pnpm

WORKDIR /workspace

CMD ["bash"]
