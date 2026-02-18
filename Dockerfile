FROM node:20 AS runtime

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

RUN mkdir -p /workspace && chown -R $USERNAME /workspace

WORKDIR /workspace

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/workspace/.bash_history" \
  && touch /workspace/.bash_history \
  && chown -R $USERNAME /workspace \
  && chmod o+rw /workspace/.bash_history


# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

USER node
ADD --chown=node:node https://opencode.ai/install /tmp/install_opencode.sh
RUN chmod +x /tmp/install_opencode.sh \
    && /tmp/install_opencode.sh \
    && rm -rf /tmp/install_opencode.sh

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  perl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY opencode.pl /
COPY config.json /home/node/config.json

USER node
ENV T_UID=1000
ENV PATH=$PATH:/home/node/.local/bin
RUN mkdir -p /workspace/workdir && chown node:node /workspace/workdir
WORKDIR /workspace/workdir
USER root
ENV OPENCODE_CONFIG=/home/node/config.json
ENV OPENCODE_CONFIG_DIR=/home/node
ENTRYPOINT ["/usr/bin/perl", "/opencode.pl"]
