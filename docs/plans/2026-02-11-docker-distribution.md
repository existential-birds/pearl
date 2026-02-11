# Docker Distribution Design

Distribute Pearl as a pre-built Docker image so users without Hex package manager access can clone the repo and run `docker compose up` with no Elixir/Hex/npm toolchain required.

## Constraints

- Target machines have Docker and access to GitHub/GHCR only (no hex.pm)
- macOS only (for now)
- Must support the Claude Code CLI provider (requires Node.js + `claude` binary inside the container)
- Postgres+pgvector must be bundled (no separate DB setup)
- Developer workflow (`mix phx.server` + `docker compose up db`) must remain unchanged

## User Experience

```bash
git clone https://github.com/existential-birds/pearl.git
cd pearl
docker compose up
# Pearl running at http://localhost:4000
```

LLM provider configuration via `.env` file or environment variables in `docker-compose.yml`. Claude Code provider requires prior authentication on the host (`~/.claude/` mounted into container).

## Architecture

### Dockerfile (`pearl/Dockerfile`)

Multi-stage build with three logical stages:

**Stage 1 — Build** (base: `hexpm/elixir:1.15.7-erlang-26.2.5-debian-bookworm`):

1. Install Hex and Rebar: `mix local.hex --force && mix local.rebar --force`
2. Set `MIX_ENV=prod`
3. Copy `mix.exs`, `mix.lock` → `mix deps.get --only prod` → `mix deps.compile`
4. Copy `config/`, `lib/`, `priv/` → `mix compile`
5. Install Node.js 24 for asset pipeline
6. Copy `assets/` → `mix assets.deploy`
7. `mix release`

**Stage 2 — Runtime** (base: `debian:bookworm-slim`):

1. Install runtime dependencies: `libstdc++6`, `openssl`, `libncurses5`, `locales`
2. Install Node.js 24+ (required for Claude CLI)
3. `npm install -g @anthropic-ai/claude-code@latest`
4. Copy release from build stage
5. Copy `docker-entrypoint.sh`
6. Expose port 4000

Estimated final image size: ~250-300MB (Debian slim + BEAM release + Node.js + Claude CLI).

### docker-compose.yml

Updated to add the `pearl` service alongside the existing `db` service:

```yaml
services:
  db:
    image: pgvector/pgvector:pg18
    ports:
      - "${PEARL_DB_PORT:-5432}:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    volumes:
      - pearl_pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  pearl:
    image: ghcr.io/existential-birds/pearl:latest
    ports:
      - "${PORT:-4000}:4000"
    depends_on:
      db:
        condition: service_healthy
    environment:
      DATABASE_URL: ecto://postgres:postgres@db/pearl_prod
      SECRET_KEY_BASE: <generate-a-default>
      PHX_SERVER: "true"
      PHX_HOST: localhost
      LLM_PROVIDER: "${LLM_PROVIDER:-openrouter}"
      LLM_MODEL: "${LLM_MODEL:-}"
      OPENROUTER_API_KEY: "${OPENROUTER_API_KEY:-}"
      OLLAMA_HOST: "${OLLAMA_HOST:-http://host.docker.internal:11434}"
    volumes:
      - ~/.claude:/root/.claude:ro
      - pearl_repos:/app/repos

volumes:
  pearl_pgdata:
  pearl_repos:
```

Key design decisions:
- `DATABASE_URL` uses container hostname `db` — no host networking needed
- `~/.claude` mounted read-only for Claude CLI authentication
- `pearl_repos` named volume persists cloned repositories across restarts
- Ollama default uses `host.docker.internal` to reach host's Ollama instance
- LLM config passed through from host environment or `.env` file
- Developers use `docker compose up db` for the existing local dev workflow

### Release Module (`lib/pearl/release.ex`)

Standard Phoenix release helper for running migrations at container startup:

```elixir
defmodule Pearl.Release do
  def migrate do
    load_app()
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  defp repos, do: Application.fetch_env!(:pearl, :ecto_repos)
  defp load_app, do: Application.ensure_all_started(:pearl)
end
```

### Entrypoint (`pearl/docker-entrypoint.sh`)

```bash
#!/bin/sh
set -e
bin/pearl eval "Pearl.Release.migrate()"
exec bin/pearl start
```

Runs migrations on every container start (no-op if already migrated), then starts the Phoenix server.

### .dockerignore

```
_build/
deps/
.git/
node_modules/
.elixir_ls/
```

## CI Pipeline (`.github/workflows/docker-publish.yml`)

Builds and pushes the Docker image to GHCR on every push to `main` and on version tags.

**Trigger:** `push` to `main` branch and `v*` tags.

**Steps:**

1. Checkout repo
2. Set up Docker Buildx (enables layer caching)
3. Log in to GHCR using automatic `GITHUB_TOKEN`
4. Build image from `pearl/Dockerfile`
5. Push with tags:
   - `ghcr.io/existential-birds/pearl:latest` on `main` push
   - `ghcr.io/existential-birds/pearl:vX.Y.Z` on version tags

**Caching:** GitHub Actions cache for Docker layers. `mix deps.get` and `npm install` layers cached independently so rebuilds are fast unless dependencies change.

**Post-setup:** GHCR package visibility must be manually set to **public** after first push (one-time, via GitHub repo Packages tab) so users can pull without authentication.

## Files to Add/Modify

| File | Action | Description |
|------|--------|-------------|
| `pearl/Dockerfile` | New | Multi-stage build with Node.js 24 + Claude CLI |
| `pearl/docker-entrypoint.sh` | New | Migrate + start script |
| `pearl/lib/pearl/release.ex` | New | Ecto migration helper for releases |
| `docker-compose.yml` | Modify | Add `pearl` service referencing GHCR image |
| `.github/workflows/docker-publish.yml` | New | Build & push to GHCR on main/tags |
| `pearl/.dockerignore` | New | Exclude build artifacts from Docker context |

## Prerequisites for Users

1. Docker Desktop installed
2. For Claude Code provider: `claude` CLI authenticated on host (run `claude` once to set up `~/.claude/`)
3. For OpenRouter: `OPENROUTER_API_KEY` set in environment or `.env` file
