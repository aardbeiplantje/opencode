FROM node:26-trixie-slim AS base

LABEL author="aardbeiplantje@gmail.com"
LABEL description="Docker image for opencode - AI-powered CLI tool with secure non-root execution environment"
LABEL version="0.1.0"

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
   less \
   git \
   ripgrep \
   procps \
   sudo \
   fzf \
   file \
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
   tshark \
   tcpdump \
   openssl \
   bash \
   openssh-client \
   && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://downloads.arduino.cc/arduino-cli/arduino-cli_1.5.0-1_amd64.deb -o /tmp/arduino-cli.deb && dpkg -i /tmp/arduino-cli.deb && rm /tmp/arduino-cli.deb

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
      python3-dev \
      python3-minimal \
      python3-requests \
      python3-scapy \
      socat \
      strace \
      tshark \
      tcpdump \
      ltrace \
      openssl \
      openssh-client \
      docker-ce \
      docker-ce-cli \
      docker-ce-rootless-extras \
      docker-compose-plugin \
      docker-buildx-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set up non-root user
USER node

ARG CACHEBUST=1

WORKDIR /home/node
ENV HDIR=/home/node
ENV PATH=$HDIR/.opencode/bin:$HDIR/.local/bin:$PATH
ENV OPENCODE_CONFIG_DIR=$HDIR/.config/opencode
ENV OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.json
COPY --chown=node:node config.json $OPENCODE_CONFIG
COPY --chown=node:node codebase-index.json $OPENCODE_CONFIG_DIR/

# opencode
ENV NPM_CONFIG_PREFIX=$HDIR/.npm-global
ENV PATH=$PATH:$HDIR/.npm-global/bin
ENV BUN_INSTALL=$HDIR/.bun
RUN npm set prefix $HDIR
RUN npm install -g npm
RUN npm install -g bun
RUN npm install -g @ai-sdk/openai-compatible
RUN npm install -g opencode-ai
RUN npm install -g opencode-codebase-index
RUN npm install -g @modelcontextprotocol/sdk zod
RUN opencode plugin @tarquinen/opencode-dcp@latest --global

# pi.dev
ENV PI_CODING_AGENT_DIR=$HDIR/.pi
ENV LEMONADE_URL=http://[::1]:13305
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent
RUN npm install -g --ignore-scripts @earendil-works/pi-agent-core
RUN npm install -g --ignore-scripts @earendil-works/pi-ai
RUN npm install -g --ignore-scripts @earendil-works/pi-tui
RUN pi install npm:fd
RUN pi install npm:pi-llama-cpp
RUN pi install git:github.com/lemonade-sdk/lemonade-pi-plugin@main
RUN pi install npm:pi-memctx
RUN pi install npm:@0xkobold/pi-codebase-wiki
COPY pi_settings.json $HDIR/.pi/settings.json
COPY pi_auth.json $HDIR/.pi/auth.json

USER root
RUN rm -rf /tmp/* /tmp/.*.so
RUN mkdir -p /workspace
RUN mkdir -p /workdir
RUN mkdir -p /opt/rocm
COPY aicli.pl /
COPY skills /skills/

USER root
ENV OPENCODE_CONFIG_DIR=/workspace
ENV T_UID=1000
ENV EDITOR=nano
ENV VISUAL=nano
ENTRYPOINT ["/usr/bin/perl", "/aicli.pl"]

FROM base AS runtime
USER root
