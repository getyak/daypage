#!/usr/bin/env bash
set -euo pipefail
docker compose -f deploy/compose.prod.yml --project-name daypage up -d --build --remove-orphans
docker image prune -f
