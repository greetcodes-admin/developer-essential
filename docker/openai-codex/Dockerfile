FROM node:20-bookworm

RUN apt-get update
RUN apt-get install -y bubblewrap patch

RUN rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex
RUN npm install -g pnpm

WORKDIR /workspace

CMD ["bash"]