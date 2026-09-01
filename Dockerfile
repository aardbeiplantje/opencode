FROM node:26-trixie-slim AS base-image

# Set up non-root user, note that 1000 works as most users have 1000
ENV LOGNAME=oc
ENV LOGNAME_UID=1000
ENV LOGNAME_GID=1000
RUN userdel node
RUN groupadd -g $LOGNAME_GID oc
RUN useradd -N -M -d /oc -u $LOGNAME_UID $LOGNAME
ENV HDIR=/oc
RUN mkdir -p $HDIR && chown oc:oc $HDIR
ENV XDG_CACHE_HOME=/pip
RUN mkdir -p $XDG_CACHE_HOME && chown oc:oc $XDG_CACHE_HOME

# Install basic development tools and iptables/ipset
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && apt-get install -y --no-install-recommends \
   curl \
   ca-certificates \
   gnupg2

RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/docker.asc] https://download.docker.com/linux/ubuntu jammy stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      perl \
      lua5.4 \
      python3 \
      python3-pip \
      python3-pip-whl \
      python3-venv \
      python3-dev \
      python3-minimal \
      python3-requests \
      python3-scapy \
      rustup \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER root

# Install basic development tools and iptables/ipset
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && apt-get install -y --no-install-recommends \
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
       gh \
       iptables \
       ipset \
       iproute2 \
       dnsutils \
       aggregate \
       jq \
       socat \
       ca-certificates \
       lsof \
       strace \
       tshark \
       tcpdump \
       openssl \
       bash \
       openssh-client \
       perl \
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

USER oc

FROM base-image AS arduino-rt

USER root
ADD https://downloads.arduino.cc/arduino-cli/arduino-cli_1.5.0-1_amd64.deb /tmp/arduino-cli.deb
RUN dpkg -i /tmp/arduino-cli.deb && rm /tmp/arduino-cli.deb

FROM base-image AS python-rt

USER oc
ENV HDIR=/oc
ENV XDG_CACHE_HOME=/cache
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV PATH=$HDIR/.local/bin:$PATH

# cocoindex + torch + ML stack
RUN \
    --mount=target=/cache,type=cache,sharing=locked,uid=1000 \
    XDG_CACHE_HOME=/cache \
    python3 -m pip install --prefer-binary --upgrade \
        ddgs \
        cocoindex-code mcp httpx \
        --extra-index-url https://repo.amd.com/rocm/whl/gfx1151/ \
        "rocm[libraries,devel]" \
        torch \
        torchvision \
        torchaudio \
        "jax_rocm7_plugin==0.9.1+rocm7.13.0" \
        "jax_rocm7_pjrt==0.9.1+rocm7.13.0" \
        "triton==3.6.0+rocm7.13.0" \
        tf-keras \
        "jax==0.9.1" \
        "jaxlib==0.9.1" \
        https://rocm.frameworks.amd.com/whl/gfx1151/flash_attn-2.8.3-py3-none-any.whl \
        accelerate \
        pygame \
        sqlalchemy comfy_aimdo blake3 alembic comfy_kitchen torchsde \
        huggingface_hub==1.19.0

FROM base-image AS perl-rt

USER oc
ENV HDIR=/oc

# Perl
RUN \
    --mount=target=/cache,type=cache,sharing=locked,uid=1000 \
    PERL_MM_USE_DEFAULT=1 \
    PERL_MM_OPT="INSTALLDIRS=site INSTALL_BASE=$HDIR/.local" \
    PERL5LIB="$HDIR/lib/perl5:$HDIR/lib/perl5/x86_64-linux-gnu-thread-multi:$HDIR/lib/perl5/x86_64-linux-gnu-thread-multi-gnu-thread-multi:$HDIR/lib/perl5/x86_64-linux-gnu-thread-multi/auto:$HDIR/lib/perl5/x86_64-linux-gnu-thread-multi-gnu-thread-multi/auto" \
    perl -MCPAN -e 'CPAN::Shell->rematein("notest","install",$_) for @ARGV' \
        JSON \
        Crypt::OpenSSL::RSA \
        Digest::SHA \
        Net::Curl \
        LWP::UserAgent \
        Term::ReadLine::Gnu \
        Data::UUID \
        JSON::PP

FROM base-image AS oc-install

USER oc
ENV HDIR=/oc

WORKDIR $HDIR
ENV PATH=$HDIR/.opencode/bin:$PATH
ENV OPENCODE_CONFIG_DIR=$HDIR/.config/opencode
ENV OPENCODE_CONFIG=$OPENCODE_CONFIG_DIR/opencode.json
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV COCOINDEX_CODE_DIR=$HDIR/.cocoindex
ENV COCOINDEX_CODE_DB_PATH_MAPPING=/workdir=/coco-db-files
ENV COCOINDEX_DISABLE_USAGE_TRACKING=1

# opencode
WORKDIR /oc
ENV NPM_CONFIG_PREFIX=$HDIR/.npm-global
ENV PATH=$PATH:$HDIR/.npm-global/bin
ENV XDG_DATA_HOME=$HDIR/oc
ENV XDG_CONFIG_HOME=$HDIR/oc
ENV XDG_CACHE_HOME=$HDIR/oc
USER root
RUN --mount=type=cache,target=/var/cache/downloads \
    curl -qsSk -L https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-x64.tar.gz \
        -z file -o /var/cache/downloads/oc.tar.gz
USER oc
RUN --mount=type=cache,target=/var/cache/downloads \
    tar xvzf /var/cache/downloads/oc.tar.gz \
    && chmod +x $HDIR/opencode \
    && $HDIR/opencode --version

COPY --chown=root:root cocoindex_plugins /lib/python/cocoindex_plugins
COPY --chown=root:root cocoindex_plugins/sitecustomize.py /lib/python/sitecustomize.py
ENV PYTHONPATH=/lib/python
RUN python3 /lib/python/cocoindex_plugins/register_providers.py

FROM base-image AS rust-rt

USER oc
ENV HDIR=/oc
ENV XDG_CACHE_HOME=/cache
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV PATH=$HDIR/.local/bin:$PATH
RUN \
    --mount=target=/cache,type=cache,sharing=locked,uid=1000 \
    CARGO_HOME=/cache \
    TMPDIR=/cache \
    rustup default stable \
    && cargo install minijinja-cli
RUN \
    --mount=target=/cache,type=cache,sharing=locked,uid=1000 \
    XDG_CACHE_HOME=/cache \
    python3 -m pip install --prefer-binary --upgrade \
        minijinja \
    || exit $?

FROM oc-install AS runtime

LABEL author="aardbeiplantje@gmail.com"
LABEL description="Docker image for opencode - AI-powered CLI tool with secure non-root execution environment"
LABEL version="0.1.0"

USER root
ENV HDIR=/oc
#COPY --from=perl-rt      /oc/ /oc/
#COPY --from=python-rt    /oc/ /oc/
#COPY --from=rust-rt      /oc/ /oc/
#COPY --from=arduino-rt   /oc/ /oc/

# Install basic development tools and iptables/ipset
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt \
    apt-get update && apt-get install -y --no-install-recommends \
       less \
       git \
       ripgrep \
       procps \
       sudo \
       fzf \
       file \
       zsh \
       unzip \
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
       lsof \
       strace \
       tshark \
       tcpdump \
       openssl \
       openssh-client \
       libwww-curl-perl \
       libnet-ssleay-perl \
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
       binutils \
       glslc \
       vulkan-tools \
       libvulkan-dev \
       spirv-headers \
       sqlite3 \
   && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN rm -rf /tmp/* /tmp/.*.so
RUN mkdir -p /workspace
RUN mkdir -p /workdir
RUN mkdir -p /opt/rocm
COPY --chown=oc:oc opencode_fn.json $OPENCODE_CONFIG
COPY tui_fn.json $OPENCODE_CONFIG_DIR/tui.json
COPY auth_fn.json $OPENCODE_CONFIG_DIR/auth.json
COPY opencode.pl /
COPY --chown=oc:oc plugins /plugins
COPY commands /commands
COPY skills /skills
COPY mcp /mcp
RUN ln -s /workspace/.opencode-mem $HDIR/.opencode-mem

USER oc
ENV XDG_CACHE_HOME=/cache
ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV PATH=$HDIR/.local/bin:$PATH
RUN \
    --mount=target=/cache,type=cache,sharing=locked,uid=1000 \
    XDG_CACHE_HOME=/cache \
    sh -c 'for r in /mcp/*/requirements.txt; do python3 -m pip install --prefer-binary --upgrade -r "$r" || exit $?; done'

ENV PIP_BREAK_SYSTEM_PACKAGES=1
ENV PIP_ROOT_USER_ACTION=ignore
ENV XDG_DATA_HOME=$HDIR/oc
ENV XDG_CONFIG_HOME=$HDIR/oc
ENV XDG_CACHE_HOME=$HDIR/oc
ENV COCOINDEX_DISABLE_USAGE_TRACKING=1
USER root
RUN mkdir -p /coco-db-files && chown oc:oc /coco-db-files
RUN ln -s /workspace/.cocoindex $HDIR/.cocoindex
ENV OPENCODE_CONFIG_DIR=/workspace
ENV EDITOR=nano
ENV VISUAL=nano
ENTRYPOINT ["/usr/bin/perl", "/opencode.pl"]
