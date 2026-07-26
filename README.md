# opencode

AI-powered CLI tool packaged as a Docker image with Docker-in-Docker (DIND) support for managing containers from within code sessions with secure non-root execution.

## 🎯 Overview

**opencode** is a Docker-based development environment that provides:
- **Docker-in-Docker (DIND)** — Start a local dockerd with `DIND=1` to manage containers from within your session
- **AI-powered CLI** — Integrated opencode agent for code sessions with local LLM inference
- **GPU acceleration** — NVIDIA CUDA and AMD ROCm support
- **Secure execution** — Automatic privilege dropping (root → non-root user)
- **Host context sharing** — Docker socket, SSH agent, git config, X11 display

---

## 📦 Architecture

| Component | Purpose |
|----------|--------|
| **Dockerfile** | Multi-stage build (~4 stages): installs Node.js 26, opencode-ai CLI, docker-ce stack |
| **opencode.pl** | Perl entry point - drops privileges, sets up environment, starts dockerd if DIND=1, then execs opencode |
| **opencode.sh** | Docker run wrapper - shares host sockets, sets env vars, launches container |
| **opencode** | Thin wrapper around `opencode.sh` with `-opencode` flag |
| **opencode.json** | Opencode agent configuration (model, tools, permissions, MCP servers) |

### Runtime Flow

```
opencode.sh (Docker run with shared volumes: docker.sock, SSH agent, git config, ROCm)
  → opencode.pl drops privileges (root→node), sets up env, starts dockerd if DIND=1
    → execs `/home/node/.npm-global/bin/opencode` (the actual CLI tool)
```

Runtime user: `node:1000`, but entrypoint may switch to configured UID via the `UID`
environment variable.

---

## Quick Start

### Running the Container

```bash
# Basic usage with Docker-in-Docker
bash opencode.sh

# Run opencode CLI specifically
bash opencode.sh -opencode

# Run pi-coding-agent
bash opencode.sh -pi
```

---

## Configuration

Set environment variables before running `opencode.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| OPENAI_API_KEY | — | LLM provider key |
| DIND | 1 | Set to `0` to disable Docker-in-Docker |
| LLAMA_MODEL | qwen3.5:0.8b | Model name (for llama.cpp) |
| LLAMA_SERVER_URL | http://[::1]:4000/v1 | LLM server base URL |
| LLAMA_SERVER_API_KEY | — | LLM server API key |
| DOCKER_HOST | — | Docker daemon socket (set for non-DIND) |
| CONTAINERD_ADDRESS | — | Containerd socket path |
| ROCM_PATH | ~/therock-dist-linux-gfx1151-latest | AMD ROCm runtime path |
| DISPLAY | — | X11 display for GUI access |
| HTTP_PROXY / HTTPS_PROXY | — | Proxy settings |
| UID | — | Override default runtime UID (default: 1000) |

### Example: Run with GPU and custom model

```bash
export LLAMA_MODEL="qwen3.5:0.8b"
export LLAMA_SERVER_API_KEY="your-key"
export ROCM_PATH="/opt/rocm"
export DISPLAY=:0
bash opencode.sh -opencode
```

### Example: Non-DIND mode (existing Docker daemon)

```bash
export DOCKER_HOST="unix:///var/run/docker.sock"
export DIND=0
bash opencode.sh -opencode
```

---

## Features

### Docker-in-Docker (DIND)
- Automatically starts local `dockerd` when `DIND=1` (default)
- Forks dockerd process with proper session handling
- Mounts Docker socket inside container for container management
- Supports GPU passthrough (`--device /dev/kfd`, `/dev/dri`)

### Security & Privilege Management
- Drops privileges: root → UID 1000 (user `node`)
- Configurable UID via `$ENV{UID}` environment variable
- Groups added: video (986), render (983), audio (992)
- Memory lock and stack limits for GPU access
- Seccomp disabled for maximum permissions when needed

### GPU Support
- **NVIDIA**: `/dev/kfd`, `/dev/dri` devices
- **AMD ROCm**: `/opt/rocm` bind-mount
- **Apple Silicon**: `/dev/accel`

### Shared Host Context
- Docker socket, SSH agent, git config, Docker config
- X11 display for GUI access
- Proxy settings (HTTP/HTTPS)
- Git authentication via environment variables

---

## 🏗️ Dockerfile Structure

### Multi-stage Build (3 Stages)

1. **`AS base`**: ~40+ development tools, Docker CE, Node.js 26, Python 3.13
2. **`AS runtime`**: Clean installs, symlink setup, environment configuration
3. **Final stage**: Copies configuration files, sets entrypoint

### Cache Busting Mechanism

To force rebuild of specific layers:

1. **Dockerfile ARG `CACHEBUST`** with default value "1"
2. Set this variable higher in `docker-bake.hcl` triggers cache invalidation

---

## 📐 Build System

### Local Build

```bash
# Local build for current platform
docker buildx bake -f docker-bake.hcl --no-cache

# With cache busting (e.g., after apt package changes)
docker buildx bake -f docker-bake.hcl --set "*.CACHEBUST=2"
```

### Multi-platform Push

```bash
# Push to a registry
docker buildx bake -f docker-bake.hcl release \
  --set "*.DOCKER_REGISTRY=ghcr.io" \
  --set "*.DOCKER_REPOSITORY=my-org" \
  --set "*.DOCKER_IMAGE_NAME=opencode" \
  --set "*.DOCKER_TAG=1.0"

# Custom image name
docker buildx bake -f docker-bake.hcl release \
  --set "*.DOCKER_IMAGE_NAME=ai-dev-tools" \
  --set "*.DOCKER_TAG=latest"
```

### Build Targets

| Target | Description |
|--------|-------------|
| `local` | Build image locally for use with `docker run` |
| `containers` | Build and push to registry (with provenance/SBOM) |

### Build Outputs

- **Provenance**: Type: `provenance`, Mode: `max`
- **SBOM**: Software Bill of Materials
- **Platform**: `linux/amd64`

---

## 🔧 Configuration (opencode.json)

The configuration file lives at `/workspace/opencode.json` inside the image.

### Configuration Schema

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama.cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-server (local)",
      "options": {
        "apiKey": "{env:LLAMA_SERVER_API_KEY}",
        "baseURL": "{env:LLAMA_SERVER_URL}"
      },
      "models": {
        "{env:LLAMA_MODEL}": {
          "name": "{env:LLAMA_MODEL}",
          "constraints": {
            "jsonMode": true
          },
          "parameters": {
            "stop": ["␣", "‪", "‭"],
            "temperature": 0.1
          }
        }
      }
    }
  },
  "model": "llama.cpp/{env:LLAMA_MODEL}",
  "permission": {
    "edit": "allow",
    "bash": "allow"
  },
  "plugin": [
    "opencode-working-memory",
    "opencode-plugin-openspec",
    "opencode-ralph-loop",
    "opencode-mem",
    "/plugins/opencode-slot-cache/manifest.js"
  ],
  "compaction": {
    "enabled": true,
    "auto": true,
    "threshold": 0.90,
    "strategy": "summarize",
    "preserveRecentMessages": 6,
    "preserveSystemPrompt": true
  },
  "mcp": {
    "ccc-granular": {
      "type": "local",
      "enabled": true,
      "command": ["python3", "/mcp/ccc_granular/server.py"]
    },
    "cocoindex-code": {
      "type": "local",
      "enabled": true,
      "command": ["ccc", "mcp"]
    }
  }
}
```

### Configuration Rules

- **Variable resolution**: Use `{env:VAR_NAME}` style substitution at runtime
- **Validation**: Uses `$schema` for opencode.ai schema validation
- **Persistence**: Config is loaded once at startup; changes require restart

### Environment Variables in Config

```json
{
  "apiKey": "{env:LLAMA_SERVER_API_KEY}",
  "baseURL": "{env:LLAMA_SERVER_URL}",
  "model": "llama.cpp/{env:LLAMA_MODEL}"
}
```

---

## 🛠️ Development Workflow

### 1. Build the Image

```bash
# Clean build
docker buildx bake -f docker-bake.hcl --no-cache

# Use cache busting
docker buildx bake -f docker-bake.hcl --set "*.CACHEBUST=2"

# Multi-platform build
docker buildx bake -f docker-bake.hcl release --set "*.DOCKER_TAG=1.0"
```

### 2. Run with Docker-in-Docker (default)

```bash
# Basic usage
bash opencode.sh

# With custom settings
export LLAMA_MODEL="qwen3.5:0.8b"
export LLAMA_SERVER_API_KEY="your-key"
bash opencode.sh -opencode
```

### 3. Run Without DIND (existing Docker daemon)

```bash
export DOCKER_HOST="unix:///var/run/docker.sock"
export DIND=0
bash opencode.sh -opencode
```

### 4. Run with GPU

```bash
export LLAMA_MODEL="qwen3.5:0.8b"
export ROCM_PATH="/opt/rocm"
export DISPLAY=:0
bash opencode.sh -opencode
```

---

## 🔐 Security Considerations

| Aspect | Status | Notes |
|--------|--------|-------|
| Privilege dropping | ✅ | Root → UID 1000 |
| Docker socket mounting | ⚠️ | Requires `--privileged=true` or host socket |
| GPU passthrough | ✅ | Requires kernel permissions |
| SSH agent sharing | ⚠️ | Script warns "dangerous" |
| Environment variables | ✅ | No hardcoded secrets |
| Config validation | ✅ | Uses `$schema` for opencode.ai |
| Memory limits | ✅ | Stack: 64MB, Memlock: unlimited |

### Security Best Practices

1. **Never expose host network** if not needed (`--network=host`)
2. **Use specific groups** instead of `--security-opt seccomp=unconfined`
3. **Avoid `--privileged=true`** if possible
4. **Verify Docker socket permissions** before mounting

---

## 📁 Project Structure

```
/workdir/opencode.git/
├── Dockerfile           # Multi-stage build (~4 stages)
├── opencode.pl            # Perl entrypoint - main logic
│   - Drop privileges (root → UID)
│   - Setup environment
│   - Start dockerd if DIND=1
│   - Execute opencode CLI
├── opencode.sh            # Docker run wrapper
│   - Share host sockets (docker.sock, SSH agent, git config)
│   - Set environment variables
│   - Launch container
├── opencode            # Thin wrapper around opencode.sh with -opencode flag
├── opencode.json       # Agent configuration
├── docker-bake.hcl     # Build targets and configuration
├── plugins/            # Custom opencode plugins
│   └── opencode-slot-cache/
├── mcp_servers/        # MCP server scripts
│   ├── ccc_granular/
│   ├── llama-slot-cache/
├── cocoindex_plugins/  # Code embedding provider
│   ├── __init__.py
│   ├── register_providers.py
│   └── llamacpp_provider/
├── skills/            # Task-specific skills (currently empty)
├── commands/          # CLI commands
│   └── purge-opencode-archived-sessions/
├── pi_auth.json       # PI authentication configuration
├── pi_settings.json   # PI configuration
├── tui.json           # TUI configuration
└── README.md          # This file
```

---

## 🎯 Use Cases

- **Code sessions** with local LLM inference using llama.cpp
- **Docker container management** from within AI-assisted workflow with DIND
- **GPU-accelerated development** (NVIDIA CUDA / AMD ROCm)
- **CI/CD integration** with provenance and SBOM generation
- **X11 development environments** with GUI support

---

## 📝 License

Unlicense (public domain) — see LICENSE.

---

## 🔗 Contributing

This is a community-maintained project. Feel free to:
- Submit bug reports
- Suggest enhancements
- Share feedback on Dockerfile optimizations
- Propose new plugins or commands

---

## 🐛 Troubleshooting

### Common Issues

#### "permission denied" errors
- Verify you have proper kernel permissions for GPU devices
- Check `--device` mounts in `opencode.sh`
- Ensure `ROCM_PATH` or `/dev/kfd` exists

#### DIND failing to start
- Check Docker host permissions
- Verify `DIND` environment variable is set to `1`
- Review dockerd logs in `/workspace/docker/*.log`

#### Config not loading
- Ensure `opencode.json` uses `$schema` for validation
- Restart the container after config changes
- Check for environment variable substitution errors

---

## 📚 References

- [opencode.ai Documentation](https://opencode.ai/)
- [Docker-in-Docker Guide](https://docs.docker.com/engine/)
- [llama.cpp Documentation](https://github.com/ggerganov/llama.cpp)
- [Model Context Protocol](https://modelcontextprotocol.io/)

---

*Last updated: 2026-07-09*
