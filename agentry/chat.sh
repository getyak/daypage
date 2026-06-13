#!/usr/bin/env bash
# Launch agentry's interactive TUI (chat) using the repo-root .env config.
#
# agentry does not read .env files itself — it only consumes process env vars —
# so this wrapper loads the repo-root .env, maps the DeepSeek credentials onto
# agentry's OpenAI-compatible provider, and starts `chat`. Run it from a real
# terminal (the TUI needs a TTY):
#
#     ./agentry/chat.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
BIN="$SCRIPT_DIR/bin/agentry"

[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found" >&2; exit 1; }
[ -x "$BIN" ] || { echo "error: $BIN missing — build with: go build -o bin/agentry ./cmd/agentry" >&2; exit 1; }

# Load .env (skip comments / blank lines) into the environment.
#
# NOTE: macOS ships bash 3.2.57, whose `source <(...)` process substitution
# breaks under `set -u` (it aborts before loading any var, so every key looks
# "not set"). Source a real temp file instead — portable back to bash 3.2.
ENV_TMP="$(mktemp -t agentry-env)"
trap 'rm -f "$ENV_TMP"' EXIT
grep -vE '^\s*#|^\s*$' "$ENV_FILE" > "$ENV_TMP"
set -a
# shellcheck disable=SC1090
source "$ENV_TMP"
set +a

# Map DeepSeek (OpenAI-compatible) onto agentry's `openai` provider.
export OPENAI_API_KEY="${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY not set in .env}"
export OPENAI_BASE_URL="${DEEPSEEK_BASE_URL:-https://api.deepseek.com/v1}"
MODEL="${DEEPSEEK_MODEL:-deepseek-chat}"

echo "→ provider=openai  base=$OPENAI_BASE_URL  model=$MODEL"
exec "$BIN" chat --provider openai --model "$MODEL" "$@"
