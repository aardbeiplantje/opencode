#!/bin/bash

DOCKER_IMAGE=${DOCKER_IMAGE:-opencode:latest}
HERE=$(readlink -f "${PWD}")
BDIR=${HERE##*/}

extra_opts=

# opencode config specified?
if [ ! -z "${OPENCODE_CONFIG}" -a -f "${OPENCODE_CONFIG}" ]; then
    extra_opts="-v ${OPENCODE_CONFIG}:${OPENCODE_CONFIG}:ro -e OPENCODE_CONFIG=$OPENCODE_CONFIG"
fi

# share ssh keys (dangerous)
if [ ! -z "$SSH_AUTH_SOCK" ]; then
    b_sock=$(readlink -f "$SSH_AUTH_SOCK")
    b_dir=${b_sock##*/}
    c_ssh_auth_sock=/dev/shm/$b_dir
    extra_opts="-v $SSH_AUTH_SOCK:/dev/shm/$b_dir -e SSH_AUTH_SOCK=$c_ssh_auth_sock $extra_opts"
fi

# Share Docker socket if available and set DOCKER_HOST
if [ ! -z "$DOCKER_HOST" ]; then
    d_sock=${DOCKER_HOST##unix://}
    if [ -S "$d_sock" ]; then
        extra_opts="-v $d_sock:/tmp/docker.sock $extra_opts"
        d_host=unix:///tmp/docker.sock
    else
        d_host=$DOCKER_HOST
    fi
else
    if [ 1 = 0 ]; then
    s_v=opencode-dind-$LOGNAME-$BDIR-dind-sock
    d_v=opencode-dind-$LOGNAME-$BDIR-dind-data
    n_v=opencode-dind-$LOGNAME-$BDIR
    ok=$(docker ps --format json -f name="$n_v"|jq -r .State)
    if [ "$ok" != "running" ]; then
        docker stop "$n_v" >/dev/null 2>&1 || true
        docker run \
            --rm \
            -d \
            --name "$n_v" \
            --privileged=true \
            -v $s_v:/dind:rw \
            -v $d_v:/var/lib/docker:rw \
            docker:dind \
              dockerd \
                -G 1000 \
                -D \
                --host=unix:///dind/docker.sock
    fi
    extra_opts="-v $s_v:/tmp/dind:rw $extra_opts"
    d_host=unix:///tmp/dind/docker.sock
    fi
fi

# Share containerd socket and config
if [ -S /run/containerd/containerd.sock ]; then
    extra_opts="-v /run/containerd/containerd.sock:/tmp/containerd.sock $extra_opts"
    c_address=/tmp/containerd.sock
fi
if [ -d /etc/containerd ]; then
    extra_opts="-v /etc/containerd:/etc/containerd:ro $extra_opts"
fi

# Share git info
if [ -f ~/.gitconfig ]; then
    fn=$(readlink -f ~/.gitconfig)
    extra_opts="-v $fn:/workspace/.gitconfig:ro $extra_opts"
fi
if [ -f ~/.gitexcludes ]; then
    fn=$(readlink -f ~/.gitexcludes)
    extra_opts="$extra_opts -v $fn:/workspace/.gitexcludes:ro $extra_opts"
fi

# Share Docker config for registry authentication and buildx state
if [ -d ~/.docker ]; then
    extra_opts="-v $HOME/.docker:/workspace/.docker $extra_opts"
fi

ROCM_PATH=${ROCM_PATH:-~/therock-dist-linux-gfx1151-latest}
ROCM_PATH=$(readlink -f "$ROCM_PATH")
exec docker run --rm -it \
    $extra_opts \
    $DOCKER_RUN_OPTS \
    -e TERM \
    -e ALL_PROXX \
    -e HTTP_PROXY \
    -e HTTPS_PROX \
    -e TMPDIR=/tmp \
    -e NODE_TLS_REJECT_UNAUTHORIZED=0 \
    -e NODE_OPTIONS="--max-old-space-size=4096" \
    -e UID=${EUID} \
    -e LOGNAME \
    -e BDIR="${BDIR}" \
    ${d_host:+-e DOCKER_HOST=$d_host} \
    ${c_address:+-e CONTAINERD_ADDRESS=$c_address} \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    -e LLAMA_SERVER_URL=${LLAMA_SERVER_URL:-http://[::]:4000/v1} \
    -e LLAMA_MODEL=${LLAMA_MODEL:-opencode.code} \
    -e GIT_AUTHOR_NAME \
    -e GIT_AUTHOR_EMAIL \
    -e GIT_COMITTER_NAME \
    -e GIT_COMITTER_EMAIL \
    -e GIT_EDITOR="true" \
    -e ROCM_PATH=/opt/rocm \
    -e OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=true \
    -e DISPLAY \
    -e DIND \
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
    -v $ROCM_PATH:/opt/rocm:ro \
    --privileged=true \
    --ulimit memlock=-1:-1 \
    --ulimit stack=67108864:67108864 \
    --group-add=video \
    --ipc=host \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --group-add 986 \
    --group-add 109 \
    --group-add 992 \
    --tmpfs /tmp:rw,suid,exec,size=2G \
    --tmpfs /var/tmp:rw,suid,exec,size=1G \
    --device /dev/kfd \
    --device /dev/dri \
    --network=host \
    --name opencode-${LOGNAME}-${BDIR} \
    -v opencode-${LOGNAME}:/workspace \
    -v "${PWD}":/workdir/${BDIR} \
        "$DOCKER_IMAGE" \
            $*
