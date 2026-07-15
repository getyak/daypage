#!/usr/bin/env bash
set -euo pipefail
install -m 600 .env web/.env.local
docker compose -f deploy/compose.prod.yml --project-name daypage up -d --build --remove-orphans
docker image prune -f
