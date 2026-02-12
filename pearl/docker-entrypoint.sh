#!/bin/sh
# pearl/docker-entrypoint.sh
#
# Docker entrypoint for Pearl.
# Runs Ecto migrations (no-op if already up-to-date), then starts the Phoenix server.
set -e

echo "==> Running database migrations..."
bin/pearl eval "Pearl.Release.migrate()"
echo "==> Migrations complete."

echo "==> Starting Pearl..."
exec bin/pearl start
