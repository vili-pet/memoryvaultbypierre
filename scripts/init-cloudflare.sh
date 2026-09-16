#!/usr/bin/env bash
# Idempotent Cloudflare initialization for MemoryVault.
# Creates or reuses D1, KV, and Vectorize bindings, then applies schema.sql.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WRANGLER_TOML="${WRANGLER_TOML:-$ROOT/wrangler.toml}"
SCHEMA_FILE="${SCHEMA_FILE:-$ROOT/schema.sql}"
DEV_VARS_FILE="${DEV_VARS_FILE:-$ROOT/.dev.vars}"
DEV_VARS_EXAMPLE="${DEV_VARS_EXAMPLE:-$ROOT/.dev.vars.example}"

MODE="local"
WRANGLER_ENV=""
APPLY_SCHEMA_ONLY=0
UPDATE_CONFIG=0
CHECK_ONLY=0
DRY_RUN=0

VECTORIZE_DIMENSIONS="${VECTORIZE_DIMENSIONS:-768}"
VECTORIZE_METRIC="${VECTORIZE_METRIC:-cosine}"

REQUIRED_D1_TABLES=(users brains memories memory_links oauth_clients)

usage() {
  cat <<'EOF'
Initialize MemoryVault Cloudflare resources and D1 schema.

Usage:
  scripts/init-cloudflare.sh --local [--apply-schema-only] [--dry-run]
  scripts/init-cloudflare.sh --remote [--env NAME] [--update-config] [--apply-schema-only] [--dry-run]
  scripts/init-cloudflare.sh --check

Options:
  --local              Local D1 schema + .dev.vars checks (default)
  --remote             Create/reuse remote D1, KV, Vectorize; apply remote schema
  --env NAME           Wrangler environment (omit for top-level / production)
  --apply-schema-only  Skip resource create/lookup; only apply schema.sql
  --update-config      Write discovered remote IDs into wrangler.toml
  --check              Print prerequisites and current bindings; no mutations
  --dry-run            Print planned actions without changing anything
  -h, --help           Show this help

Prerequisites:
  Node.js 20+, npm, Wrangler 4 (via npx wrangler)
  --remote also requires `npx wrangler login` (or CLOUDFLARE_API_TOKEN)

Secrets (never committed):
  AUTH_SECRET   JWT signing + legacy bearer auth
  ADMIN_TOKEN   Required for POST /register (except trusted claude.ai / poke.com clients)
  OAUTH_REDIRECT_DOMAIN_ALLOWLIST  Optional extra OAuth redirect hosts

Local secrets live in .dev.vars (see .dev.vars.example).
Production secrets: npx wrangler secret put AUTH_SECRET
                    npx wrangler secret put ADMIN_TOKEN
EOF
}

log() { printf '[init-cloudflare] %s\n' "$*" >&2; }
warn() { printf '[init-cloudflare] WARNING: %s\n' "$*" >&2; }
fail() { printf '[init-cloudflare] ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

wrangler() {
  npx --no-install wrangler "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --remote) MODE="remote"; shift ;;
    --env)
      [[ $# -ge 2 ]] || fail "--env requires a name"
      WRANGLER_ENV="$2"
      shift 2
      ;;
    --apply-schema-only) APPLY_SCHEMA_ONLY=1; shift ;;
    --update-config) UPDATE_CONFIG=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

toml_get() {
  node "$ROOT/scripts/lib/wrangler-toml.mjs" get "$WRANGLER_TOML" "${1:-}" "$2" "$3"
}

toml_set() {
  node "$ROOT/scripts/lib/wrangler-toml.mjs" set "$WRANGLER_TOML" "${1:-}" "$2" "$3" "$4"
}

print_bindings() {
  local env_label="${1:-production}"
  local env_name="${2:-}"
  printf '\nBindings (%s):\n' "$env_label"
  printf '  D1 name:            %s\n' "$(toml_get "$env_name" d1 database_name || echo '(missing)')"
  printf '  D1 database_id:     %s\n' "$(toml_get "$env_name" d1 database_id || echo '(missing)')"
  printf '  KV binding:         RATE_LIMIT_KV\n'
  printf '  KV id:              %s\n' "$(toml_get "$env_name" kv id || echo '(missing)')"
  printf '  Vectorize index:    %s\n' "$(toml_get "$env_name" vectorize index_name || echo '(missing)')"
}

check_dev_vars() {
  local copy_if_missing="${1:-0}"
  if [[ ! -f "$DEV_VARS_FILE" ]]; then
    if [[ -f "$DEV_VARS_EXAMPLE" && "$copy_if_missing" -eq 1 ]]; then
      log "No .dev.vars found. Copying from .dev.vars.example"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run] cp %s %s\n' "$DEV_VARS_EXAMPLE" "$DEV_VARS_FILE" >&2
      else
        cp "$DEV_VARS_EXAMPLE" "$DEV_VARS_FILE"
      fi
      warn "Edit .dev.vars and replace placeholder AUTH_SECRET / ADMIN_TOKEN values before using auth."
    elif [[ ! -f "$DEV_VARS_FILE" ]]; then
      warn "No .dev.vars found. Copy with: cp .dev.vars.example .dev.vars"
    fi
    return
  fi

  local missing=0
  for key in AUTH_SECRET ADMIN_TOKEN; do
    if ! grep -Eq "^${key}=" "$DEV_VARS_FILE"; then
      warn ".dev.vars is missing ${key}"
      missing=1
    elif grep -Eq "^${key}=replace-with-" "$DEV_VARS_FILE"; then
      warn ".dev.vars still has a placeholder value for ${key}"
    fi
  done
  if [[ "$missing" -eq 0 ]]; then
    log ".dev.vars is present (values not printed)"
  fi
}

check_prereqs() {
  need_cmd node
  need_cmd npm
  need_cmd npx
  [[ -f "$WRANGLER_TOML" ]] || fail "Missing $WRANGLER_TOML"
  [[ -f "$SCHEMA_FILE" ]] || fail "Missing $SCHEMA_FILE"

  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "$node_major" -ge 20 ]] || fail "Node.js 20+ is required (found $(node -v))"

  log "Node $(node -v), npm $(npm -v)"
  if ! npx --no-install wrangler --version >/dev/null 2>&1; then
    warn "Wrangler is not installed locally. Install with: npm install"
    warn "Remote commands will fail until wrangler is available."
  else
    log "Wrangler $(npx --no-install wrangler --version 2>/dev/null | head -n1)"
  fi
}

wrangler_logged_in() {
  wrangler whoami >/dev/null 2>&1
}

extract_json() {
  node --input-type=module - "$1" <<'NODE'
const raw = process.argv[2];
const start = Math.min(
  ...['[', '{'].map((ch) => {
    const idx = raw.indexOf(ch);
    return idx === -1 ? Number.POSITIVE_INFINITY : idx;
  })
);
if (!Number.isFinite(start)) process.exit(1);
process.stdout.write(raw.slice(start));
NODE
}

json_find_id() {
  # json_find_id <json> <match-field> <match-value> <id-field> [alt-id-field]
  local payload
  payload="$(extract_json "$1")"
  node --input-type=module - "$payload" "$2" "$3" "$4" "${5:-}" <<'NODE'
const data = JSON.parse(process.argv[2]);
const field = process.argv[3];
const expected = process.argv[4];
const idField = process.argv[5];
const altIdField = process.argv[6] || '';
const rows = Array.isArray(data) ? data : (data.indexes || data.result || data.namespaces || []);
const hit = rows.find((row) => row && String(row[field]) === expected);
if (!hit) process.exit(1);
const value = hit[idField] ?? (altIdField ? hit[altIdField] : null);
if (value == null) process.exit(1);
process.stdout.write(String(value));
NODE
}

ensure_d1() {
  local name="$1"
  log "Checking D1 database: $name"
  local list
  list="$(wrangler d1 list --json)"
  local uuid
  uuid="$(json_find_id "$list" name "$name" uuid id 2>/dev/null || true)"
  if [[ -n "${uuid:-}" ]]; then
    log "Reusing existing D1 '$name' ($uuid)"
    printf '%s' "$uuid"
    return
  fi
  log "Creating D1 database '$name'"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] wrangler d1 create %s\n' "$name" >&2
    printf 'dry-run-d1-id'
    return
  fi
  local out
  out="$(wrangler d1 create "$name")"
  uuid="$(printf '%s\n' "$out" | sed -n 's/.*database_id = "\([^"]*\)".*/\1/p' | tail -n1)"
  [[ -n "$uuid" ]] || fail "Created D1 '$name' but could not parse database_id from wrangler output"
  log "Created D1 '$name' ($uuid)"
  printf '%s' "$uuid"
}

ensure_kv() {
  local title="$1"
  log "Checking KV namespace: $title"
  local list
  list="$(wrangler kv namespace list)"
  local id
  id="$(json_find_id "$list" title "$title" id 2>/dev/null || true)"
  if [[ -n "${id:-}" ]]; then
    log "Reusing existing KV '$title' ($id)"
    printf '%s' "$id"
    return
  fi
  log "Creating KV namespace '$title'"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] wrangler kv namespace create %s\n' "$title" >&2
    printf 'dry-run-kv-id'
    return
  fi
  local out
  out="$(wrangler kv namespace create "$title")"
  id="$(printf '%s\n' "$out" | sed -n 's/.*id = "\([^"]*\)".*/\1/p' | tail -n1)"
  [[ -n "$id" ]] || fail "Created KV '$title' but could not parse id from wrangler output"
  log "Created KV '$title' ($id)"
  printf '%s' "$id"
}

ensure_vectorize() {
  local name="$1"
  log "Checking Vectorize index: $name"
  local list
  list="$(wrangler vectorize list --json 2>/dev/null || wrangler vectorize list)"
  local exists payload
  payload="$(extract_json "$list" 2>/dev/null || true)"
  exists="$(node --input-type=module - "${payload:-}" "$name" <<'NODE' || true
const raw = process.argv[2];
const name = process.argv[3];
if (!raw) process.exit(1);
let data;
try { data = JSON.parse(raw); } catch { process.exit(1); }
const rows = Array.isArray(data) ? data : (data.indexes || data.result || []);
const hit = rows.find((row) => (row.name || row.id) === name);
process.stdout.write(hit ? 'yes' : 'no');
NODE
)"
  if [[ "$exists" == "yes" ]]; then
    log "Reusing existing Vectorize index '$name'"
    return
  fi
  log "Creating Vectorize index '$name' (${VECTORIZE_DIMENSIONS} dims, ${VECTORIZE_METRIC})"
  run wrangler vectorize create "$name" --dimensions="$VECTORIZE_DIMENSIONS" --metric="$VECTORIZE_METRIC"
}

d1_flags() {
  local flags=()
  if [[ "$MODE" == "remote" ]]; then
    flags+=(--remote)
  else
    flags+=(--local)
  fi
  if [[ -n "$WRANGLER_ENV" ]]; then
    flags+=(--env "$WRANGLER_ENV")
  fi
  printf '%s\n' "${flags[@]}"
}

apply_schema() {
  local name="$1"
  local target
  if [[ "$MODE" == "remote" ]]; then
    target="remote"
  else
    target="local"
  fi
  log "Applying $SCHEMA_FILE to D1 '$name' ($target) — idempotent CREATE IF NOT EXISTS"
  local flags=()
  mapfile -t flags < <(d1_flags)
  run wrangler d1 execute "$name" "${flags[@]}" --file="$SCHEMA_FILE"
}

verify_schema() {
  local name="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Skipping schema verification in dry-run"
    return
  fi
  local flags=()
  mapfile -t flags < <(d1_flags)
  local tables
  tables="$(wrangler d1 execute "$name" "${flags[@]}" --json --command="SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")"
  local missing=()
  local table
  for table in "${REQUIRED_D1_TABLES[@]}"; do
    if ! printf '%s' "$tables" | grep -q "\"$table\""; then
      missing+=("$table")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Schema verification failed; missing tables: ${missing[*]}"
  fi
  log "Schema verification passed (${#REQUIRED_D1_TABLES[@]} required tables present)"
}

check_remote_secrets() {
  local extra=()
  if [[ -n "$WRANGLER_ENV" ]]; then
    extra+=(--env "$WRANGLER_ENV")
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would check remote secret names (values never printed)"
    return
  fi
  if ! wrangler_logged_in; then
    warn "Not logged in; skip remote secret check. Run: npx wrangler login"
    return
  fi
  local listed
  if ! listed="$(wrangler secret list "${extra[@]}" 2>/dev/null)"; then
    warn "Could not list remote secrets. Set them with wrangler secret put."
    return
  fi
  for key in AUTH_SECRET ADMIN_TOKEN; do
    if printf '%s' "$listed" | grep -q "$key"; then
      log "Remote secret $key is set (value not printed)"
    else
      warn "Remote secret $key is not set. Run: npx wrangler secret put $key${WRANGLER_ENV:+ --env $WRANGLER_ENV}"
    fi
  done
}

print_check() {
  check_prereqs
  print_bindings "production" ""
  if grep -q '^\[env.dev\]' "$WRANGLER_TOML"; then
    print_bindings "env.dev" "dev"
  fi
  printf '\nLocal secrets:\n'
  if [[ -f "$DEV_VARS_FILE" ]]; then
    printf '  .dev.vars is present (values not printed)\n'
    for key in AUTH_SECRET ADMIN_TOKEN; do
      if ! grep -Eq "^${key}=" "$DEV_VARS_FILE"; then
        printf '  WARNING: .dev.vars is missing %s\n' "$key"
      elif grep -Eq "^${key}=replace-with-" "$DEV_VARS_FILE"; then
        printf '  WARNING: placeholder value still set for %s\n' "$key"
      fi
    done
  else
    printf '  missing — copy with: cp .dev.vars.example .dev.vars\n'
  fi
  printf '\nWrangler login:\n'
  if wrangler_logged_in; then
    log "Logged in to Cloudflare"
    wrangler whoami || true
  else
    warn "Not logged in. Local D1 still works. Remote init needs: npx wrangler login"
  fi
  printf '\nNext steps:\n'
  printf '  Local:  npm run cf:init:local && npm run dev\n'
  printf '  Remote: npm run cf:init:remote && npx wrangler secret put AUTH_SECRET && npm run deploy\n'
}

init_local() {
  check_prereqs
  check_dev_vars 1
  local d1_name
  d1_name="$(toml_get "" d1 database_name)"
  [[ -n "$d1_name" ]] || fail "Could not read D1 database_name from wrangler.toml"
  if [[ "$APPLY_SCHEMA_ONLY" -eq 0 ]]; then
    log "Local mode does not create remote KV/Vectorize. Bindings in wrangler.toml are used as-is."
    log "Workers AI + Vectorize are unavailable in fully local miniflare; use wrangler dev --remote for semantic search."
  fi
  apply_schema "$d1_name"
  verify_schema "$d1_name"
  log "Local initialization complete."
  log "Start the worker with: npm run dev"
  log "MCP endpoint: http://127.0.0.1:8787/mcp"
}

init_remote() {
  check_prereqs
  if [[ "$DRY_RUN" -eq 0 ]] && ! wrangler_logged_in; then
    fail "Remote init requires Cloudflare auth. Run: npx wrangler login"
  fi

  local d1_name kv_title vectorize_name
  d1_name="$(toml_get "$WRANGLER_ENV" d1 database_name)"
  vectorize_name="$(toml_get "$WRANGLER_ENV" vectorize index_name)"
  [[ -n "$d1_name" ]] || fail "Could not read D1 database_name from wrangler.toml"
  [[ -n "$vectorize_name" ]] || fail "Could not read Vectorize index_name from wrangler.toml"

  if [[ -n "$WRANGLER_ENV" ]]; then
    kv_title="RATE_LIMIT_KV_${WRANGLER_ENV}"
  else
    kv_title="RATE_LIMIT_KV"
  fi

  local d1_id kv_id
  if [[ "$APPLY_SCHEMA_ONLY" -eq 0 ]]; then
    d1_id="$(ensure_d1 "$d1_name")"
    kv_id="$(ensure_kv "$kv_title")"
    ensure_vectorize "$vectorize_name"
    if [[ "$UPDATE_CONFIG" -eq 1 ]]; then
      log "Updating wrangler.toml with discovered IDs"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run] set %s d1.database_id=%s\n' "${WRANGLER_ENV:-production}" "$d1_id" >&2
        printf '[dry-run] set %s kv.id=%s\n' "${WRANGLER_ENV:-production}" "$kv_id" >&2
      else
        toml_set "$WRANGLER_ENV" d1 database_id "$d1_id"
        toml_set "$WRANGLER_ENV" kv id "$kv_id"
        log "Wrote D1 database_id and KV id into wrangler.toml (${WRANGLER_ENV:-production})"
      fi
    else
      local current_d1 current_kv
      current_d1="$(toml_get "$WRANGLER_ENV" d1 database_id || true)"
      current_kv="$(toml_get "$WRANGLER_ENV" kv id || true)"
      if [[ "$current_d1" != "$d1_id" || "$current_kv" != "$kv_id" ]]; then
        warn "wrangler.toml IDs differ from the Cloudflare account resources."
        warn "  D1 toml=$current_d1 account=$d1_id"
        warn "  KV  toml=$current_kv account=$kv_id"
        warn "Re-run with --update-config to write the account IDs into wrangler.toml."
      fi
    fi
  fi

  apply_schema "$d1_name"
  verify_schema "$d1_name"
  check_remote_secrets
  log "Remote initialization complete."
  log "Deploy with: npm run deploy${WRANGLER_ENV:+ -- --env $WRANGLER_ENV}"
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  print_check
  exit 0
fi

if [[ "$MODE" == "remote" ]]; then
  init_remote
else
  init_local
fi
