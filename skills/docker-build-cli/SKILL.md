---
name: docker-build-cli
description: "Use when you need to build, push, pull or run Docker images on the K8s cluster without MCP. Drive the DinD build pod and internal registry from a shell."
version: 1.0.0
license: MIT
metadata:
  hermes:
    tags: [docker, build, kubernetes, dind, registry, cli, agent]
    related_skills: [k8s-infra-install, k8s-web-deploy]
---

# Docker Build Factory — CLI for AI agents (no MCP required)

Drive the Kubernetes Docker-in-Docker build pod and its internal registry from a
plain shell. This is the transport-free alternative to the bundled MCP server: no
config file to edit, no agent restart, works in any agent that can run a shell
command with `kubectl` access to the namespace.

## When to use

- You need to build/push/pull/run a Docker image on the cluster.
- The machine has **no local Docker** — the build happens inside the cluster.
- You want a portable path that works across agents (Claude Code, Codex, OpenCode,
  Hermes, a human) instead of a per-client MCP configuration.
- Prefer this over the MCP server when: the MCP server is unavailable, the agent
  cannot be restarted, or the client does not speak MCP.

## Prerequisites

- `kubectl` with access to the target namespace (permanent — used on every call).
- `KUBE_NAMESPACE` set (there is **no implicit namespace**), or an `.env` at the
  repo root carrying it. `KUBECTL` may override the kubectl path.
- The factory deployed in that namespace: a `docker-build` pod (dind) and a
  `registry` service on `registry:5000`. Deploy once with
  `./docker-build-setup.sh` (Helm chart in `chart/`).

## Commands

All commands live in `./docker-build-cli.sh`:

| Command | Action | MCP equivalent |
|---------|--------|----------------|
| `build IMAGE [CONTEXT_DIR]` | Build from a directory containing `Dockerfile` | `docker_build` |
| `push IMAGE` | Tag + push to `registry:5000` | `docker_push` |
| `pull IMAGE` | Pull from the registry | `docker_pull` |
| `run IMAGE [COMMAND...]` | Run the image once (`--rm`) | `docker_run` |
| `images` | List local images inside the pod | `docker_list_images` |
| `registry` | List images in the registry (catalog) | `docker_list_registry` |
| `cleanup` | Prune unused Docker data in the pod | `docker_cleanup` |

### Examples

```bash
export KUBE_NAMESPACE=mi-agent
export KUBECTL=/workspace/kubectl        # only if kubectl is off-PATH

./docker-build-cli.sh build myapp:1.2.3 ./my-app
./docker-build-cli.sh push  myapp:1.2.3
./docker-build-cli.sh registry
./docker-build-cli.sh run   registry:5000/myapp:1.2.3
```

## Workflow

1. `build IMAGE CONTEXT` — streams the context into the pod, runs `docker build`
   there. The image lives **inside the pod** (its `emptyDir` storage).
2. `push IMAGE` — tags as `registry:5000/IMAGE` and pushes. **Do this before the
   pod is recreated**: deleting the pod wipes its local image cache.
3. `registry` — confirm the image landed (`GET /v2/_catalog`).
4. `run IMAGE` — optional smoke test of the pushed image.

## Pitfalls

- The image is **not** on the local machine and is **not** kept across pod
  restarts — always `push` what you want to keep.
- No implicit namespace: an unset `KUBE_NAMESPACE` is an error by design.
- `kubectl` must stay installed and configured: every command shells out to it.
- Building requires a `Dockerfile` in the context directory; the script fails
  locally before touching the cluster if it is missing.
- Tag images explicitly with a version/SHA — never `latest` (blocked by policy).

## MCP vs CLI

Both target the same pod and registry. Use MCP when the client natively supports
it and you want structured tool calls; use this CLI when you want zero setup,
portability, or a fallback. The two can coexist — installing the MCP server does
not affect the CLI.
