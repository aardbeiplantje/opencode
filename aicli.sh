#!/bin/bash

DOCKER_IMAGE=${DOCKER_IMAGE:-local/ai/opencode:latest}
HERE=$(readlink -f "${PWD}")
BDIR=${HERE##*/}

extra_opts=

w=${1:--opencode}
shift
echo "running $w"

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
    echo "check $d_sock"
    if [ -S "$d_sock" ]; then
        extra_opts="-v $d_sock:/var/run/docker.sock $extra_opts"
        d_host=unix:///var/run/docker.sock
        echo "using DOCKER_HOST=$d_host"
    else
        d_host=$DOCKER_HOST
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

if [ "${DIND:-0}" = "1" ]; then
    extra_opts="$extra_opts -e DIND --privileged=true"
fi

ROCM_PATH=${ROCM_PATH:-/opt/rocm}
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
    -e DOCKER_CONFIG=/workspace/.docker \
    -e BDIR="${BDIR}" \
    ${d_host:+-e DOCKER_HOST=$d_host} \
    ${c_address:+-e CONTAINERD_ADDRESS=$c_address} \
    -e GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" \
    -e LLAMA_SERVER_URL=${LLAMA_SERVER_URL:-http://[::1]:8000/v1} \
    -e LEMONADE_URL=${LEMONADE_URL:-http://[::1]:13305/api/v1} \
    -e LLAMA_SERVER_API_KEY \
    -e LLAMA_MODEL=${LLAMA_MODEL:-qwen3.5:0.8b} \
    -e INDEX_MODEL=${INDEX_MODEL:-embeddinggemma-300M-Q8_0} \
    -e GIT_AUTHOR_NAME \
    -e GIT_AUTHOR_EMAIL \
    -e GIT_COMITTER_NAME \
    -e GIT_COMITTER_EMAIL \
    -e GIT_EDITOR="true" \
    -e ROCM_PATH=/opt/rocm \
    -e DISPLAY \
    -v /tmp/.X11-unix:/tmp/.X11-unix:ro \
    -v $ROCM_PATH:/opt/rocm:ro \
    -v aicli-${w##-}-${LOGNAME}-${BDIR}-cocodb:/coco-db-files:rw \
    --ulimit memlock=-1:-1 \
    --ulimit stack=67108864:67108864 \
    --group-add=video \
    --ipc=host \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --group-add 986 \
    --group-add 109 \
    --group-add 992 \
    --tmpfs /home/node/.cocoindex:rw,suid,exec,uid=1000,size=1M \
    --tmpfs /tmp:rw,suid,exec,size=2G \
    --tmpfs /var/tmp:rw,suid,exec,size=1G \
    --device /dev/kfd \
    --device /dev/dri \
    --device /dev/accel \
    --network=host \
    --name ${w##-}-${LOGNAME}-${BDIR} \
    -v aicli-${w##-}-${LOGNAME}-workspace:/workspace \
    -v "${PWD}":/workdir/${BDIR} \
        "$DOCKER_IMAGE" \
            $w $*
