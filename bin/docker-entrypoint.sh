#!/bin/sh
set -eu

# Pearl Docker Entrypoint
# Runs database migrations then starts the Phoenix server.
#
# Usage:
#   docker-entrypoint.sh start    – migrate + start server (default)
#   docker-entrypoint.sh migrate  – run migrations only
#   docker-entrypoint.sh eval "..." – run an arbitrary eval command
#   docker-entrypoint.sh remote   – attach a remote IEx console

log() { printf '[pearl] %s\n' "$*"; }

setup_database() {
  log "Ensuring database exists..."
  /app/bin/pearl eval "Pearl.Release.create_db()"
  log "Running database migrations..."
  /app/bin/pearl eval "Pearl.Release.migrate()"
  log "Migrations complete."
}

case "${1:-start}" in
  start)
    setup_database
    log "Starting Pearl server on port ${PORT:-4000}..."
    exec /app/bin/pearl start
    ;;
  migrate)
    setup_database
    ;;
  eval)
    shift
    exec /app/bin/pearl eval "$@"
    ;;
  remote)
    exec /app/bin/pearl remote
    ;;
  *)
    exec /app/bin/pearl "$@"
    ;;
esac
