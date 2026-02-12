# ============================================================================
# Pearl – Multi-stage Docker build
#
# Produces a minimal runtime image with a BEAM release, pre-built assets,
# Node.js (for esbuild/tailwind), and git (for repository cloning).
#
# Usage:
#   docker build -t pearl .
#   docker compose up
# ============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build – compile Elixir release and assets
# ---------------------------------------------------------------------------
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.3
ARG DEBIAN_CODENAME=bookworm
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_CODENAME}-20250428"
ARG RUNNER_IMAGE="debian:${DEBIAN_CODENAME}-slim"

FROM ${BUILDER_IMAGE} AS build

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 LTS (needed for npm deps used by esbuild/tailwind)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Set build environment
ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency manifests first for better layer caching
COPY pearl/mix.exs pearl/mix.lock ./
RUN mix deps.get --only $MIX_ENV && \
    mix deps.compile

# Copy config (needed before compile for compile-time config)
COPY pearl/config/config.exs pearl/config/${MIX_ENV}.exs config/
COPY pearl/config/runtime.exs config/

# Copy application source
COPY pearl/lib lib/
COPY pearl/priv priv/

# Install npm deps for asset pipeline
COPY pearl/assets/package.json pearl/assets/package-lock.json* assets/
RUN cd assets && npm install --omit=dev

# Copy remaining asset sources and compile them
COPY pearl/assets assets/
RUN mix assets.deploy

# Compile the application
RUN mix compile

# Build the release
RUN mix release

# ---------------------------------------------------------------------------
# Stage 2: Runtime – minimal image with the release
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

# Install runtime dependencies:
# - libstdc++6: required by BEAM
# - openssl: TLS support
# - libncurses5: BEAM remote console
# - locales: proper UTF-8 support
# - git: Pearl clones repos at runtime
# - ca-certificates: HTTPS for API calls
# - curl: health checks
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales \
      git ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

# Create a non-root user for the release
RUN groupadd --system pearl && \
    useradd --system --gid pearl --home /app --shell /bin/sh pearl && \
    mkdir -p /app/repos && \
    chown -R pearl:pearl /app

# Copy the release from the build stage
COPY --from=build --chown=pearl:pearl /app/_build/prod/rel/pearl ./

# Copy entrypoint script
COPY --chown=pearl:pearl bin/docker-entrypoint.sh /app/bin/docker-entrypoint.sh
RUN chmod +x /app/bin/docker-entrypoint.sh

USER pearl

# Default environment variables
ENV PHX_SERVER=true \
    PORT=4000 \
    PHX_HOST=localhost

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsSL http://localhost:4000/ || exit 1

ENTRYPOINT ["/app/bin/docker-entrypoint.sh"]
CMD ["start"]
