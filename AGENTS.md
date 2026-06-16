# Opencode Agent Instructions (AGENTS.md)

This repository packages **opencode** (AI-powered CLI tool) as a Docker image with
Docker-in-Docker support, non-root execution, and configurable agent settings.

## Key Files

| File             | Purpose                                                         |
|------------------|-----------------------------------------------------------------|
| `Dockerfile`     | Multi-stage build: installs Node.js 26, opencode-ai CLI, docker-ce stack (~4 stages) |
| `aicli.pl`       | Perl entry point - drops privileges (root → UID), sets up env, starts dockerd if DIND=1, then execs opencode |
| `aicli.sh`       | Docker run wrapper - shares host sockets, sets env vars, launches container |
| `opencode`       | Thin wrapper around `aicli.sh` with `-opencode` flag |
| `docker-bake.hcl`| Docker BuildKit bake config for building/pushing images to a registry |
| `config.json`    | Opencode agent config (model, tools, permissions, MCP servers)  |

## Project Structure

- **Build:** Use `docker buildx bake` (defined in `docker-bake.hcl`). Pushes to
  `${DOCKER_REGISTRY}/${DOCKER_REPOSITORY}/${DOCKER_IMAGE_NAME}:${DOCKER_TAG}`.
  Set defaults via variables or edit `docker-bake.hcl`.

## Runtime Flow

```
aicli.sh (Docker run with shared volumes: docker.sock, SSH agent, git config, ROCm)
  → aicli.pl drops privileges (root→node), sets up env, starts dockerd if DIND=1
    → execs `/home/node/.npm-global/bin/opencode` (the actual CLI tool)
```

Runtime user: `node:1000`, but entrypoint may switch to configured UID via the `UID`
environment variable.

## Opencode Config (`config.json`)

The config lives at `/home/node/config.json` inside the image. Edit rules:

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
