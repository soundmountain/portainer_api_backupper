#!/usr/bin/env bash
set -euo pipefail

# ====== CONFIG ======
ENV_FILE="/path/to/env/folder/.env"

# ===== Description =====
# Author: https://github.com/soundmountain
# This script creates a 
# - backup of all docker-compose files and metadata
# - a standard backup of portainer
# utilizing the portainer API

# ====== USAGE ======
# create an .env file with the following values
# PORTAINER_URL="https://portainer.example.com"
# PORTAINER_API_KEY="YOUR_ACCESS_TOKEN"
# BACKUP_DIR="/path/to/backup/location"
# CLEANUP_BACKUP=true|false
# KEEP_BACKUPS=7
# CURL_CONNECT_TIMEOUT=10
# CURL_MAX_TIME=180
# CURL_RETRY=3
# CURL_RETRY_DELAY=2
# CURL_RETRY_ALL_ERRORS=1
# # optional: password for encrypted portainer backup
# # PORTAINER_BACKUP_PASSWORD="changeme2somethingsecure"
# # optional, when using a self signed certificate: 
# # CURL_INSECURE=1
# 
# ===== harden the file a little bit =====
# chmod 700 /path/to/env/folder
# chmod 600 /path/to/env/folder/.env

# ===== run the script =====
# bash ./portainer_api_backupper.sh

# Optional: load .env if there is one
if [[ -n "${ENV_FILE:-}" ]]; then
  if [[ -f "${ENV_FILE}" ]]; then
    echo "loading env from: ${ENV_FILE}"
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  else
    echo "! ENV_FILE not found: ${ENV_FILE}" >&2
    exit 1
  fi
fi

: "${PORTAINER_URL:?missing: PORTAINER_URL}"
: "${PORTAINER_API_KEY:?missing: PORTAINER_API_KEY}"

CURL_INSECURE="${CURL_INSECURE:-0}"

BACKUP_DIR="${BACKUP_DIR:-./portainer-compose-backups}"
STAMP="$(date +%F)"             # YYYY-MM-DD
OUT_DIR="${BACKUP_DIR}/${STAMP}"
mkdir -p "${OUT_DIR}"

# Curl timeouts/retries (configurable via env)
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-120}"
CURL_RETRY="${CURL_RETRY:-3}"
CURL_RETRY_DELAY="${CURL_RETRY_DELAY:-2}"
CURL_RETRY_ALL_ERRORS="${CURL_RETRY_ALL_ERRORS:-1}"

# Compose common retry/timeout args
curl_retry_args=(
  --connect-timeout "$CURL_CONNECT_TIMEOUT"
  --max-time "$CURL_MAX_TIME"
  --retry "$CURL_RETRY"
  --retry-delay "$CURL_RETRY_DELAY"
)
if [[ "$CURL_RETRY_ALL_ERRORS" == "1" ]]; then
  curl_retry_args+=(--retry-all-errors)
fi

# POST JSON and download binary response
curl_post_json_download() {
  local path="$1"
  local json_body="$2"
  local outfile="$3"
  local args=(-fsS -X POST -H "X-API-Key: ${PORTAINER_API_KEY}" -H "Content-Type: application/json; charset=utf-8" "${curl_retry_args[@]}")
  if [[ "$CURL_INSECURE" == "1" ]]; then
    args+=(-k)
  fi
  curl "${args[@]}" --data "${json_body}" --output "${outfile}" "${PORTAINER_URL%/}${path}"
}

# ====== 0) full Portainer backup via API (optional) ======
echo "creating Portainer backup..."

# Build JSON body (password optional)
json_body="$(jq -nc --arg password "${PORTAINER_BACKUP_PASSWORD:-}" '{password:$password}')"

backup_file="${OUT_DIR}/portainer-backup_${STAMP}.tar.gz"
path_primary="/api/backup"

if ! curl_post_json_download "$path_primary" "$json_body" "$backup_file"; then
  echo "! Warnung: Portainer Backup-Endpunkt fehlgeschlagen (Pfad: $path_primary)" >&2
fi

curl_common=(
  -fsS
  -H "X-API-Key: ${PORTAINER_API_KEY}"
  -H "Accept: application/json"
  "${curl_retry_args[@]}"
)

if [[ "$CURL_INSECURE" == "1" ]]; then
  curl_common+=(-k)
fi

api_get() {
  local path="$1"
  curl "${curl_common[@]}" "${PORTAINER_URL%/}${path}"
}

# ====== 1) loading endpoints (id -> name) ======
echo "loading endpoints..."
endpoints_json="$(api_get "/api/endpoints")"

# Map Endpoint-ID -> Name
# fallback to "endpoint-<id>", in case of an empty name.
declare -A EP_NAME
while read -r id name; do
  [[ -z "$name" || "$name" == "null" ]] && name="endpoint-${id}"
  EP_NAME["$id"]="$name"
done < <(echo "$endpoints_json" | jq -r '.[] | "\(.Id) \(.Name)"')

# ====== 2) load all stacks ======
echo "loading stacks..."
stacks_json="$(api_get "/api/stacks")"
count_total="$(echo "$stacks_json" | jq 'length')"
echo "stacks found: $count_total"

# ====== 3) backup compose file per stack ======
echo "$stacks_json" | jq -c '.[]' | while read -r stack; do
  id="$(echo "$stack" | jq -r '.Id')"
  name="$(echo "$stack" | jq -r '.Name')"
  endpoint_id="$(echo "$stack" | jq -r '.EndpointId')"
  type="$(echo "$stack" | jq -r '.Type')"   # 1=Swarm, 2=Standalone, 3=K8s (portainer internal codes)
  ep_name="${EP_NAME[$endpoint_id]:-endpoint-${endpoint_id}}"

  # friendly foldername
  safe_ep="$(echo "$ep_name" | tr ' /:' '___')"
  safe_stack="$(echo "$name" | tr ' /:' '___')"
  target_dir="${OUT_DIR}/${safe_ep}"
  mkdir -p "$target_dir"

  echo "  - ${ep_name}: Stack '${name}' (ID ${id})"

  # get compose-file
  file_json="$(api_get "/api/stacks/${id}/file" || true)"

  # some stacks may be missing StackFileContent (e.g. k8s or git-based)
  # Portainer can return either a JSON envelope { StackFileContent: "..." }
  # or raw compose content (plain text). Handle both without noisy jq errors.
  stackfile=""
  if [[ -n "${file_json}" ]]; then
    if [[ "${file_json}" == \{* ]]; then
      # Looks like JSON -> try to extract StackFileContent, suppress jq stderr
      stackfile="$(printf "%s" "${file_json}" | jq -r 'try .StackFileContent // empty' 2>/dev/null || true)"
      # If JSON is present but no StackFileContent, keep empty (git/K8s stacks)
    else
      # Not JSON -> assume raw compose content
      stackfile="${file_json}"
    fi
  fi

  # set file extension
  ext="yaml"
  if [[ -n "$stackfile" ]]; then
    :
  fi

  target_file="${target_dir}/stack_${safe_stack}-${id}.${ext}"
  meta_file="${target_dir}/stack_${safe_stack}-${id}.metadata.json"

  if [[ -n "$stackfile" ]]; then
    printf "%s" "$stackfile" > "$target_file"
  else
    # in case of missing compose files
    echo "    (StackFileContent missing - writing metadata)"
  fi

  # write metadata
  echo "$stack" | jq '{
      Id, Name, EndpointId, Type,
      Created: (.CreationDate? // .Created?),
      Updated: (.UpdateDate? // .Updated?),
      Git: (.GitConfig? // null),
      SwarmID: (.SwarmId? // null),
      ProjectPath: (.ProjectPath? // null),
      Namespace: (.Namespace? // null)
    }' > "$meta_file"

  # for git-stacks: repo/ref/compose-path as README
  git_url="$(echo "$stack" | jq -r '.GitConfig?.URL // empty')"
  if [[ -z "$stackfile" && -n "$git_url" ]]; then
    {
      echo "git-based stack:"
      echo "  Repo:       $(echo "$stack" | jq -r '.GitConfig.URL')"
      echo "  Reference:  $(echo "$stack" | jq -r '.GitConfig.ReferenceName // "refs/heads/main"')"
      echo "  Compose:    $(echo "$stack" | jq -r '.GitConfig.ConfigFilePath // "docker-compose.yml"')"
    } > "${target_dir}/stack_${safe_stack}-${id}.README.txt"
  fi
done

if [ "${CLEANUP_BACKUP}" = "true" ]; then
    MTIME="${KEEP_BACKUPS:-7}"
    echo "cleaning up old backups (mtime +${MTIME})"
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$MTIME" -exec echo "removing: {}" \; -exec rm -rf {} \;
fi

echo "✓ Done! Backups located in: ${OUT_DIR}"
