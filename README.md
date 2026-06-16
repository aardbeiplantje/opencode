# opencode

AI-powered CLI tool packaged as a Docker image with Docker-in-Docker support for managing containers from within code sessions.

## Quick Start

```bash
bash aicli.sh
```

Or run with a specific subcommand:

```bash
bash aicli.sh -opencode          # run opencode CLI
bash aicli.sh -pi                # run pi-coding-agent
```

## Configuration

Set environment variables before running `aicli.sh`:

| Variable                   | Default                                      | Description                              |
|----------------------------|----------------------------------------------|------------------------------------------|
| OPENAI_API_KEY             | —                                            | LLM provider key                         |
| DIND                       | 1                                            | Set to `0` to disable Docker-in-Docker   |
| LLAMA_MODEL                | qwen3.5:0.8b                                 | Model name (for llama.cpp)               |
| LLAMA_SERVER_URL           | http://[::]:4000/v1                          | LLM server base URL                      |
| LLAMA_SERVER_API_KEY       | —                                            | LLM server API key                       |
| DOCKER_HOST                | —                                            | Docker daemon socket (set for non-DIND)  |
| CONTAINERD_ADDRESS         | —                                            | Containerd socket path                   |
| ROCM_PATH                  | ~/therock-dist-linux-gfx1151-latest          | AMD ROCm runtime path                    |
| DOCKER_IMAGE               | local/ai/opencode:latest                     | Docker image to run                      |

## Features

- **Docker-in-Docker** — Start a local dockerd with `DIND=1` (default) to manage containers from within your session
- **GPU support** — NVIDIA CUDA runtime (`--device /dev/kfd`, `/dev/dri`) and AMD ROCm (`ROCM_PATH` bind mount)
- **Privilege dropping** — Automatic root → non-root user switching before running the agent
- **Shared host context** — Docker socket, SSH agent, gitconfig, `.docker` config, X11 display

## Build

```bash
# Local build for current platform
docker buildx bake -f docker-bake.hcl --no-cache

# Multi-platform push to a registry
docker buildx bake -f docker-bake.hcl release --set "*.tags=ghcr.io/my-org/opencode:1.0"
```

Customize bake variables by passing `--set`, e.g.:
```bash
docker buildx bake -f docker-bake.hcl release --set "*.DOCKER_REGISTRY=ghcr.io" --set "*.DOCKER_REPOSITORY=my-org" --set "*.DOCKER_IMAGE_NAME=opencode" --set "*.DOCKER_TAG=1.0"
```

## License

Unlicense (public domain) — see LICENSE.
