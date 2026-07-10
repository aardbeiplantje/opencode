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
      git \
      cmake \
      ninja-build \
      build-essential \
      binutils \
      nasm \
      clang \
      pkg-config \
      glslc \
      vulkan-tools \
      libvulkan-dev \
      spirv-headers \
      sqlite3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER root

RUN mkdir -p /workspace/.local \
    && rm -rf $HDIR/.local; \
    ln -sfT /workspace/.local $HDIR/.local \
    && chown node:node /workspace/.local

# Set up non-root user
USER node

WORKDIR /home/node
ENV HDIR=/home/node
ENV PATH=$HDIR/.opencode/bin:$HDIR/.local/bin:$PATH
ENV OPENCODE_CONFIG_DIR=$HDIR/.config/opencode
ENV OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.json

# opencode
ENV NPM_CONFIG_PREFIX=$HDIR/.npm-global
ENV PATH=$PATH:$HDIR/.npm-global/bin
ENV BUN_INSTALL=$HDIR/.bun
RUN npm set prefix $HDIR
RUN npm install -g npm
RUN npm install -g bun
RUN npm install -g @ai-sdk/openai-compatible
RUN npm install -g opencode-ai
RUN npm install -g opencode-working-memory
RUN npm install -g @modelcontextprotocol/sdk zod
RUN npm install -g opencode-plugin-openspec
RUN npm install -g opencode-mem
RUN opencode plugin @tarquinen/opencode-dcp@latest --global
RUN chmod +x $HDIR/.npm-global/bin/*

# pi.dev
ENV PI_CODING_AGENT_DIR=$HDIR/.pi/agent
ENV LEMONADE_URL=http://[::1]:13305
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent
RUN npm install -g --ignore-scripts @earendil-works/pi-agent-core
RUN npm install -g --ignore-scripts @earendil-works/pi-ai
RUN npm install -g --ignore-scripts @earendil-works/pi-tui
RUN pi install npm:fd
RUN pi install git:github.com/aardbeiplantje/pi-llama@feature/llama-slot-handling
RUN pi install git:github.com/aardbeiplantje/lemonade-pi-plugin@feature-llama.cpp-slot-id
RUN pi install npm:pi-memctx
RUN pi install npm:@0xkobold/pi-codebase-wiki
RUN pi install npm:pi-mcp-extension
RUN pi install npm:@termdraw/pi

# cocoindex
USER root
ENV TMPDIR=/pip/tmp
ENV XDG_CACHE_HOME=/pip
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV COCOINDEX_CODE_DIR=$HDIR/.cocoindex
ENV COCOINDEX_CODE_DB_PATH_MAPPING=/workdir=/coco-db-files
ENV COCOINDEX_DISABLE_USAGE_TRACKING=1

RUN mkdir -p $TMPDIR && chmod +s $TMPDIR
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        cocoindex-code mcp httpx

FROM base AS runtime
USER root

USER root
RUN mkdir -p /workspace/.local
USER node
RUN rm -rf $HDIR/.local \
    && ln -sfT /workspace/.local $HDIR/.local \
    && chown node:node /workspace/.local
USER root
RUN rm -rf /tmp/* /tmp/.*.so /workspace/.local
RUN mkdir -p /workspace
RUN mkdir -p /workdir
RUN mkdir -p /opt/rocm
COPY --chown=node:node opencode.json $OPENCODE_CONFIG
COPY tui.json $OPENCODE_CONFIG_DIR/tui.json
COPY aicli.pl /
COPY mcp_servers /mcp
COPY --chown=root:root cocoindex_plugins /cocoindex_plugins
COPY pi_settings.json $HDIR/.pi/agent/settings.json
COPY pi_auth.json $HDIR/.pi/agent/auth.json
COPY --chown=node:node plugins /plugins
COPY commands /commands
COPY skills /skills
RUN ln -s /workspace/.opencode-mem /home/node/.opencode-mem
USER root
ENV TMPDIR=/pip/tmp
ENV XDG_CACHE_HOME=/pip
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV COCOINDEX_CODE_DIR=$HDIR/.cocoindex
ENV COCOINDEX_CODE_DB_PATH_MAPPING=/workdir=/coco-db-files
ENV COCOINDEX_DISABLE_USAGE_TRACKING=1
RUN mkdir -p /coco-db-files && chown node:node /coco-db-files
RUN mkdir -p /usr/local/lib/python3.13/dist-packages/cocoindex_plugins && cp /cocoindex_plugins/__init__.py /usr/local/lib/python3.13/dist-packages/cocoindex_plugins/ && cp /cocoindex_plugins/register_providers.py /usr/local/lib/python3.13/dist-packages/cocoindex_plugins/ && cp -r /cocoindex_plugins/llamacpp_provider /usr/local/lib/python3.13/dist-packages/cocoindex_plugins/ && cp /cocoindex_plugins/sitecustomize.py /usr/lib/python3.13/ && chown -R root:root /usr/local/lib/python3.13/dist-packages/cocoindex*
RUN ln -s /workspace/.cocoindex /home/node/.cocoindex
ENV OPENCODE_CONFIG_DIR=/workspace
ENV T_UID=1000
ENV EDITOR=nano
ENV VISUAL=nano
ENTRYPOINT ["/usr/bin/perl", "/aicli.pl"]
