#!/usr/bin/env bash
# Run Earshot locally with all required --dart-define secrets.
# Copy .env.local.example to .env.local and fill in your keys before running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env.local"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ .env.local not found."
  echo "   Copy .env.local.example to .env.local and fill in your API keys."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [[ -z "${PODCAST_INDEX_API_KEY:-}" || -z "${PODCAST_INDEX_API_SECRET:-}" ]]; then
  echo "❌ PODCAST_INDEX_API_KEY and PODCAST_INDEX_API_SECRET must be set in .env.local."
  exit 1
fi

echo "▶ Running Earshot with dart-define secrets..."
flutter run \
  --dart-define=PODCAST_INDEX_API_KEY="$PODCAST_INDEX_API_KEY" \
  --dart-define=PODCAST_INDEX_API_SECRET="$PODCAST_INDEX_API_SECRET" \
  --dart-define=SENTRY_DSN="${SENTRY_DSN:-}" \
  --dart-define=POSTHOG_API_KEY="${POSTHOG_API_KEY:-}" \
  "$@"
