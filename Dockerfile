FROM node:26-trixie-slim AS runtime

LABEL author="aardbeiplantje@gmail.com"
LABEL description="Docker image for opencode - AI-powered CLI tool with secure non-root execution environment"
LABEL version="0.1.0"

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
   socat \
   ca-certificates \
   curl \
  lsof \
  strace \
  openssl \
  bash \
  openssh-client \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set up non-root user
USER node

ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=$PATH:/home/node/.npm-global/bin
ENV PATH=/home/node/.opencode/bin:/home/node/.local/bin:$PATH
ENV BUN_INSTALL=/home/node/.bun
RUN npm set prefix /home/node/
RUN npm install -g npm
RUN npm install -g bun
RUN npm install -g @ai-sdk/openai-compatible
RUN npm install -g opencode-ai
WORKDIR /workspace
RUN opencode run "dummy"

USER root
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      perl \
      libwww-curl-perl \
      libnet-ssleay-perl \
      lua5.4 \
      make \
      gcc \
      g++ \
      python3 \
      python3-pip \
      python3-pip-whl \
      python3-venv \
      python3-requests \
      docker-ce \
      docker-ce-cli \
      docker-ce-rootless-extras \
      docker-compose-plugin \
      docker-buildx-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN rm -rf /tmp/* /tmp/.*.so
COPY opencode.pl /
COPY config.json /home/node/config.json

USER root
WORKDIR /workspace
ENV PATH=/home/node/.opencode/bin:/home/node/.local/bin:$PATH
ENV OPENCODE_CONFIG=/home/node/config.json
ENV OPENCODE_CONFIG_DIR=/workspace
ENV T_UID=1000
ENV EDITOR=nano
ENV VISUAL=nano
ENTRYPOINT ["/usr/bin/perl", "/opencode.pl"]
