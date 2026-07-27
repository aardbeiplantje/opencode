# Opencode Agent Instructions (AGENTS.md)

This repository packages **opencode** (AI-powered CLI tool) as a Docker image with
Docker-in-Docker support, non-root execution, and configurable agent settings.

## Project Overview
**opencode** is an AI-powered CLI tool designed to provide a secure, Docker-based development environment. It features Docker-in-Docker (DIND) support, GPU acceleration (NVIDIA and AMD), and integrates with local LLMs via `llama.cpp`.

### Key Features
- **Docker-in-Docker (DIND):** Allows managing containers from within the session.
- **Security:** Automatically drops privileges from `root` to a non-root user (`node`).
- **AI Integration:** Configurable via `opencode.json`, supporting local LLMs and the Model Context Protocol (MCP).
- **GPU Acceleration:** Supports NVIDIA CUDA and AMD ROCm for high-performance AI tasks.
- **Shared Context:** Integrates with the host's Docker socket, SSH agent, and Git configuration.

### Architecture & Workflow
1. **`opencode.sh`**: A Docker run wrapper that sets up environment variables and shares host sockets.
2. **`opencode.pl`**: A Perl entry point that handles privilege dropping and starts `dockerd` if DIND is enabled.
3. **`opencode` CLI**: The main tool that executes within the container.

### Project Structure
- `commands/`: Contains CLI command implementations.
- `mcp_servers/`: Implements Model Context Protocol servers.
- `plugins/`: Custom plugins for extending opencode functionality (currently empty).
- `skills/`: Task-specific workflows.
- `cocoindex_plugins/`: Provides code embedding capabilities (llamacpp LiteLLM providers).
- `opencode.json`: The central configuration file for models, permissions, and plugins.

## Key Files

| File             | Purpose                                                         |
|------------------|-----------------------------------------------------------------|
| `Dockerfile`     | Multi-stage build: installs Node.js 26, opencode-ai CLI, docker-ce stack. CocoIndex LiteLLM providers registered at build time via `register_providers.py` |
| `opencode.pl`       | Perl entry point - drops privileges (root → UID), sets up env, starts dockerd if DIND=1, then execs opencode |
| `opencode.sh`       | Docker run wrapper - shares host sockets, sets env vars, launches container |
| `opencode`       | Thin wrapper around `opencode.sh` with `-opencode` flag |
| `docker-bake.hcl`| Docker BuildKit bake config for building/pushing images to a registry |
| `opencode.json`    | Opencode agent config (model, tools, permissions, MCP servers)  |

## Build System

- **Build:** Use `docker buildx bake` (defined in `docker-bake.hcl`). Pushes to
  `${DOCKER_REGISTRY}/${DOCKER_REPOSITORY}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}`.
  Set defaults via variables or edit `docker-bake.hcl`.

## Runtime Flow

```
opencode.sh (Docker run with shared volumes: docker.sock, SSH agent, git config, ROCm)
  → opencode.pl drops privileges (root→node), sets up env, starts dockerd if DIND=1
    → execs `/home/node/.npm-global/bin/opencode` (the actual CLI tool)
```

Note: CocoIndex LiteLLM providers are registered at Docker build time, not at runtime.

Runtime user: `node:1000`, but entrypoint may switch to configured UID via the `UID`
environment variable.

## Opencode Config (`opencode.json`)

The config lives at `/workspace/opencode.json` inside the image. Edit rules:

- Use `$schema: "https://opencode.ai/config.json"` for validation
- Variables resolve via `{env:LLAMA_MODEL}` style substitution at runtime
- After saving, restart opencode (config is loaded once at startup)

## Docker / In-Docker

- The image installs `docker-ce`, `containerd`, and related packages so that containers
  inside can manage outer-host Docker.
- Sockets are shared via bind mounts (`/var/run/docker.sock`).
- Containerd socket can be shared via `CONTAINERD_ADDRESS` env var.
- GPU support includes both NVIDIA (`--device /dev/kfd`, `/dev/dri`) and AMD ROCm
  (`ROCM_PATH` bind-mounted to `/opt/rocm`).

## Conventions

- No hardcoded secrets in config or scripts - use env vars (`LLAMA_MODEL`, `OPENAI_API_KEY`)
- Commit messages follow `<type>: <description>` with standard types: `feat:`, `fix:`,
  `refactor:`, `chore:`, `docs:`
- Dockerfile installs grouped logically within a single `apt-get` to minimize layers

## Cache Busting Mechanism

To force a rebuild of specific layers during Docker image builds (particularly useful when testing changes to apt packages or other cached steps), the project now supports:

1. A **Dockerfile ARG `CACHEBUST`** with default value "1"
2. Setting this variable higher in docker-bake.hcl triggers cache invalidation

## Helpful Commands / Docs

See `README.md` for build, config, and DIND documentation.

Skills provide specialized instructions and workflows for specific tasks.
Use the skill tool to load a skill when a task matches its description.
