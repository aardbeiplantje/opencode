FROM node:24 AS runtime

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
  && apt-get clean && rm -rf /var/lib/apt/lists/*

ARG USERNAME=node

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

USER node
ENV PATH=/home/node/.opencode/bin:/home/node/.local/bin:$PATH
ENV BUN_INSTALL=/home/node/.bun
ADD --chown=node:node https://opencode.ai/install /tmp/install_opencode.sh
WORKDIR /workspace
RUN chmod +x /tmp/install_opencode.sh \
    && bash /tmp/install_opencode.sh \
    && opencode run "dummy" \
    && rm -rf /tmp/install_opencode.sh

USER root
RUN npm install -g npm
RUN npm install -g bun

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  perl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY opencode.pl /
COPY config.json /home/node/config.json

USER root
WORKDIR /workspace
ENV PATH=/home/node/.opencode/bin:/home/node/.local/bin:$PATH
ENV OPENCODE_CONFIG=/home/node/config.json
ENV OPENCODE_CONFIG_DIR=/workspace
ENV T_UID=1000
ENTRYPOINT ["/usr/bin/perl", "/opencode.pl"]
