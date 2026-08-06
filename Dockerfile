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
      xxd \
      gdb \
      rustup \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER root

RUN mkdir -p /workspace/.local \
    && rm -rf $HDIR/.local; \
    ln -sfT /workspace/.local $HDIR/.local \
    && chown node:node /workspace/.local

ENV XDG_CACHE_HOME=/pip
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore

USER root

# cocoindex
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        ddgs

RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade  --ignore-installed \
        cocoindex-code mcp httpx

# install torch
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        --index-url https://repo.amd.com/rocm/whl/gfx1151/ \
        "rocm[libraries,devel]" \
        torch \
        torchvision \
        torchaudio \
        || exit $?
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        --extra-index-url https://repo.amd.com/rocm/whl/gfx1151/ \
        "jax_rocm7_plugin==0.9.1+rocm7.13.0" \
        "jax_rocm7_pjrt==0.9.1+rocm7.13.0" \
        "triton==3.6.0+rocm7.13.0" \
        tf-keras \
        || exit $?
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        "jax==0.9.1" \
        "jaxlib==0.9.1" \
        || exit $?
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        https://rocm.frameworks.amd.com/whl/gfx1151/flash_attn-2.8.3-py3-none-any.whl \
        || exit $?

RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        accelerate \
        pygame \
        sqlalchemy comfy_aimdo blake3 alembic comfy_kitchen torchsde \
        || exit $?

RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    python3 -m pip install --prefer-binary --upgrade \
        huggingface_hub==1.19.0 \
        || exit $?

# Perl
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("JSON")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("Crypt::OpenSSL::RSA")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("Digest::SHA")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("Net::Curl")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("LWP::UserAgent")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("Term::ReadLine::Gnu")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("Data::UUID")'
RUN PERL5LIB="/home/node/perl5/lib/perl5" perl -MCPAN -e 'CPAN::Shell->install("JSON::PP")'


# Set up non-root user
USER node

WORKDIR /home/node
ENV HDIR=/home/node
ENV PATH=$HDIR/.opencode/bin:$HDIR/.local/bin:$PATH
ENV OPENCODE_CONFIG_DIR=$HDIR/.config/opencode
ENV OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.json
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV COCOINDEX_CODE_DIR=$HDIR/.cocoindex
ENV COCOINDEX_CODE_DB_PATH_MAPPING=/workdir=/coco-db-files
ENV COCOINDEX_DISABLE_USAGE_TRACKING=1

# opencode
ENV NPM_CONFIG_PREFIX=$HDIR/.npm-global
ENV PATH=$PATH:$HDIR/.npm-global/bin
ENV XDG_CACHE_HOME=/var/tmp/
ENV BUN_INSTALL=$HDIR/.bun
RUN npm set prefix $HDIR
RUN npm install -g npm
RUN npm install -g bun
RUN npm install -g @ai-sdk/openai-compatible
RUN npm install -g @modelcontextprotocol/sdk zod
RUN npm install -g opencode-working-memory
RUN npm install -g opencode-plugin-openspec
RUN npm install -g opencode-mem
RUN npm install -g opencode-linux-x64
RUN npm install -g opencode-ai
RUN npm install -g @tarquinen/opencode-dcp@latest
#ADD https://opencode.ai/install.sh /install.sh
#RUN bash /install.sh && rm -f /install.sh
#ENV PATH=/home/node/.npm-global/lib/node_modules/opencode-linux-x64/bin/:$PATH
RUN chmod +x $HDIR/.npm-global/bin/*
#RUN opencode plugin @tarquinen/opencode-dcp@latest --global


USER root
COPY --chown=root:root cocoindex_plugins /lib/python/cocoindex_plugins
COPY --chown=root:root cocoindex_plugins/sitecustomize.py /lib/python/sitecustomize.py
ENV PYTHONPATH=/lib/python
RUN python3 /lib/python/cocoindex_plugins/register_providers.py


FROM base AS runtime
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
COPY opencode.pl /
COPY --chown=node:node plugins /plugins
COPY commands /commands
COPY skills /skills
COPY mcp /mcp
RUN ln -s /workspace/.opencode-mem /home/node/.opencode-mem
USER root
RUN \
    --mount=target=/pip,type=cache,sharing=locked \
    for r in /mcp/*/requirements.txt; do \
        python3 -m pip install --prefer-binary --upgrade \
            -r $r; \
    done

ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV COCOINDEX_DISABLE_USAGE_TRACKING=1
RUN mkdir -p /coco-db-files && chown node:node /coco-db-files
RUN ln -s /workspace/.cocoindex /home/node/.cocoindex
ENV OPENCODE_CONFIG_DIR=/workspace
ENV EDITOR=nano
ENV VISUAL=nano
ENTRYPOINT ["/usr/bin/perl", "/opencode.pl"]
