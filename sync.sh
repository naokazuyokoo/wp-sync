#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.sync"
RSYNC_IGNORE_FILE="${SCRIPT_DIR}/.rsyncignore"

usage() {
  cat <<'USAGE'
Usage:
  bash sync.sh <source_env> <target_env> <component>

Args:
  source_env: local | prod
  target_env: local | prod
  component : db | theme | plugins | upload | all

Examples:
  bash sync.sh prod local db
  bash sync.sh local prod all
USAGE
}

if [[ $# -ne 3 ]]; then
  usage
  exit 1
fi

SRC_ENV="$1"
DST_ENV="$2"
COMPONENT_RAW="$3"

# Load site-specific configuration.
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[ERROR] ${ENV_FILE} not found. Copy ${SCRIPT_DIR}/.env.sync.example to .env.sync first."
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${PROD_HOST:?PROD_HOST is required}"
: "${PROD_PATH:?PROD_PATH is required}"
: "${PROD_URL:?PROD_URL is required}"
: "${LOCAL_PATH:?LOCAL_PATH is required}"
: "${LOCAL_URL:?LOCAL_URL is required}"

SSH_PORT="${SSH_PORT:-}"
SSH_KEY="${SSH_KEY:-}"
LOCAL_WP_ALLOW_ROOT="${LOCAL_WP_ALLOW_ROOT:-0}"
PROD_WP_ALLOW_ROOT="${PROD_WP_ALLOW_ROOT:-0}"
TMP_DIR="${TMP_DIR:-/tmp}"
BACKUP_ENABLE="${BACKUP_ENABLE:-1}"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"

# Validate basic runtime arguments and settings.
if [[ "${SRC_ENV}" == "${DST_ENV}" ]]; then
  echo "[ERROR] source_env and target_env must be different."
  exit 1
fi

if [[ "${SRC_ENV}" != "local" && "${SRC_ENV}" != "prod" ]]; then
  echo "[ERROR] source_env must be local or prod."
  exit 1
fi

if [[ "${DST_ENV}" != "local" && "${DST_ENV}" != "prod" ]]; then
  echo "[ERROR] target_env must be local or prod."
  exit 1
fi

if [[ "${BACKUP_ENABLE}" != "0" && "${BACKUP_ENABLE}" != "1" ]]; then
  echo "[ERROR] BACKUP_ENABLE must be 0 or 1."
  exit 1
fi

if ! [[ "${BACKUP_KEEP}" =~ ^[0-9]+$ ]] || [[ "${BACKUP_KEEP}" -lt 1 ]]; then
  echo "[ERROR] BACKUP_KEEP must be an integer >= 1."
  exit 1
fi

normalize_component() {
  case "$1" in
    d|db) echo "db" ;;
    t|theme|themes) echo "theme" ;;
    p|plugin|plugins) echo "plugins" ;;
    u|upload|uploads) echo "upload" ;;
    a|all) echo "all" ;;
    *)
      echo ""
      ;;
  esac
}

COMPONENT="$(normalize_component "${COMPONENT_RAW}")"
if [[ -z "${COMPONENT}" ]]; then
  echo "[ERROR] component must be db/theme/plugins/upload/all."
  exit 1
fi

LOCAL_PATH="${LOCAL_PATH%/}"
PROD_PATH="${PROD_PATH%/}"

LOCAL_PARENT_DIR="$(dirname "${LOCAL_PATH}")"
PROD_PARENT_DIR="$(dirname "${PROD_PATH}")"
BACKUP_DIR_LOCAL="${BACKUP_DIR_LOCAL:-${LOCAL_PARENT_DIR}/.sync-backups}"
BACKUP_DIR_PROD="${BACKUP_DIR_PROD:-${PROD_PARENT_DIR}/.sync-backups}"

LOCAL_WP_ARGS=(--path="${LOCAL_PATH}")
if [[ "${LOCAL_WP_ALLOW_ROOT}" == "1" ]]; then
  LOCAL_WP_ARGS+=(--allow-root)
fi

PROD_WP_ALLOW_ROOT_ARG=""
if [[ "${PROD_WP_ALLOW_ROOT}" == "1" ]]; then
  PROD_WP_ALLOW_ROOT_ARG=" --allow-root"
fi

# Build and execute SSH command with optional overrides.
ssh_base_cmd() {
  local -a cmd
  cmd=(ssh)
  if [[ -n "${SSH_PORT}" ]]; then
    cmd+=(-p "${SSH_PORT}")
  fi
  if [[ -n "${SSH_KEY}" ]]; then
    cmd+=(-i "${SSH_KEY}")
  fi
  cmd+=("${PROD_HOST}" "$@")
  "${cmd[@]}"
}

local_wp() {
  wp "${LOCAL_WP_ARGS[@]}" "$@"
}

prod_wp_cmd() {
  local subcmd="$1"
  printf "wp --path='%s' %s%s" "${PROD_PATH}" "${subcmd}" "${PROD_WP_ALLOW_ROOT_ARG}"
}

ensure_wp_cli() {
  if ! command -v wp >/dev/null 2>&1; then
    echo "[ERROR] local wp command is not available."
    exit 1
  fi
}

ensure_base_commands() {
  local cmd
  for cmd in ssh rsync; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "[ERROR] required command not found: ${cmd}"
      exit 1
    fi
  done
}

confirm_push() {
  if [[ "${SRC_ENV}" == "local" && "${DST_ENV}" == "prod" ]]; then
    echo "[WARN] You are pushing to production. target: ${COMPONENT}"
    read -r -p "Continue? [y/N] " confirm
    if [[ "${confirm}" != "y" ]]; then
      echo "Cancelled."
      exit 1
    fi
  fi
}

warn_backup_dir_visibility() {
  if [[ "${BACKUP_ENABLE}" != "1" ]]; then
    return 0
  fi

  if [[ "${DST_ENV}" == "prod" && "${BACKUP_DIR_PROD}" == "${PROD_PATH}"* ]]; then
    echo "[WARN] BACKUP_DIR_PROD is inside PROD_PATH (possibly public)."
    echo "[WARN] Prefer a non-public path, or deny web access to backup directory."
  fi
}

sync_db() {
  ensure_wp_cli

  local ts dump_file backup_local backup_remote
  ts="$(date +%Y%m%d%H%M%S)"
  dump_file="${TMP_DIR}/sync-${SRC_ENV}-to-${DST_ENV}-${ts}.sql"

  if [[ "${DST_ENV}" == "local" ]]; then
    # Always take a pre-import snapshot so restore is possible even when rsync backup is disabled.
    backup_local="${TMP_DIR}/local-db-backup-${ts}.sql"
    echo "Local DB backup: ${backup_local}"
    local_wp db export "${backup_local}"
  else
    backup_remote="/tmp/prod-db-backup-${ts}.sql"
    echo "Production DB backup: ${backup_remote}"
    ssh_base_cmd "$(prod_wp_cmd "db export '${backup_remote}'")"
  fi

  echo "Export DB from ${SRC_ENV}"
  if [[ "${SRC_ENV}" == "local" ]]; then
    local_wp db export "${dump_file}"
  else
    ssh_base_cmd "$(prod_wp_cmd "db export -")" > "${dump_file}"
  fi

  echo "Import DB to ${DST_ENV}"
  if [[ "${DST_ENV}" == "local" ]]; then
    local_wp db import "${dump_file}"
  else
    cat "${dump_file}" | ssh_base_cmd "$(prod_wp_cmd "db import -")"
  fi

  local src_url dst_url src_url_esc dst_url_esc
  if [[ "${SRC_ENV}" == "prod" ]]; then
    src_url="${PROD_URL}"
    dst_url="${LOCAL_URL}"
  else
    src_url="${LOCAL_URL}"
    dst_url="${PROD_URL}"
  fi

  src_url_esc="${src_url//\//\\/}"
  dst_url_esc="${dst_url//\//\\/}"

  echo "URL replace (${src_url} -> ${dst_url})"
  if [[ "${DST_ENV}" == "local" ]]; then
    local_wp search-replace "${src_url}" "${dst_url}" --all-tables --precise --recurse-objects
    local_wp search-replace "${src_url_esc}" "${dst_url_esc}" --all-tables --precise
    local_wp cache flush || true
    local_wp rewrite flush || true
  else
    ssh_base_cmd "$(prod_wp_cmd "search-replace '${src_url}' '${dst_url}' --all-tables --precise --recurse-objects")"
    ssh_base_cmd "$(prod_wp_cmd "search-replace '${src_url_esc}' '${dst_url_esc}' --all-tables --precise")"
    ssh_base_cmd "$(prod_wp_cmd "cache flush")" || true
    ssh_base_cmd "$(prod_wp_cmd "rewrite flush")" || true
  fi

  rm -f "${dump_file}"
  echo "DB sync completed (${SRC_ENV} -> ${DST_ENV})"
}

rsync_with_ssh() {
  local from="$1"
  local to="$2"
  shift 2

  local -a cmd
  cmd=(rsync -avz --progress --delete)

  local backup_parent="" backup_dir=""
  if [[ "${BACKUP_ENABLE}" == "1" ]]; then
    local backup_base backup_scope
    if [[ "${DST_ENV}" == "local" ]]; then
      backup_base="${BACKUP_DIR_LOCAL%/}"
    else
      backup_base="${BACKUP_DIR_PROD%/}"
    fi

    backup_scope="${COMPONENT}-${SRC_ENV}-to-${DST_ENV}"
    backup_parent="${backup_base}/${backup_scope}"
    backup_dir="${backup_parent}/${RUN_TS}"

    if [[ "${DST_ENV}" == "local" ]]; then
      mkdir -p "${backup_dir}"
    else
      ssh_base_cmd "mkdir -p $(printf "%q" "${backup_dir}")"
    fi

    cmd+=(--backup "--backup-dir=${backup_dir}")
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    cmd+=(--dry-run)
  fi

  if [[ -f "${RSYNC_IGNORE_FILE}" ]]; then
    cmd+=("--exclude-from=${RSYNC_IGNORE_FILE}")
  fi

  while [[ $# -gt 0 ]]; do
    cmd+=("$1")
    shift
  done

  local rsh="ssh"
  if [[ -n "${SSH_PORT}" ]]; then
    rsh="${rsh} -p ${SSH_PORT}"
  fi
  if [[ -n "${SSH_KEY}" ]]; then
    rsh="${rsh} -i ${SSH_KEY}"
  fi

  cmd+=(-e "${rsh}" "${from}" "${to}")

  echo "Run: ${cmd[*]}"
  "${cmd[@]}"

  if [[ "${BACKUP_ENABLE}" == "1" ]]; then
    echo "Backup saved: ${backup_dir}"
    echo "Keep latest ${BACKUP_KEEP} generations under: ${backup_parent}"

    if [[ "${DST_ENV}" == "local" ]]; then
      local total
      total="$(ls -1 "${backup_parent}" 2>/dev/null | wc -l | tr -d '[:space:]')"
      if [[ "${total}" -gt "${BACKUP_KEEP}" ]]; then
        local remove_count i
        remove_count=$((total - BACKUP_KEEP))
        i=0
        while IFS= read -r d; do
          [[ -z "${d}" ]] && continue
          i=$((i + 1))
          if [[ "${i}" -le "${remove_count}" ]]; then
            rm -rf "${backup_parent}/${d}"
            echo "Pruned backup: ${backup_parent}/${d}"
          fi
        done < <(ls -1 "${backup_parent}" 2>/dev/null)
      fi
    else
      local prune_script
      # Keep pruning on remote side to avoid transferring directory listings.
      prune_script=$(
        cat <<EOF
set -eu
parent=$(printf "%q" "${backup_parent}")
keep=${BACKUP_KEEP}
[ -d "\$parent" ] || exit 0
total=\$(ls -1 "\$parent" 2>/dev/null | wc -l | tr -d '[:space:]')
[ "\$total" -gt "\$keep" ] || exit 0
remove_count=\$((total - keep))
i=0
for d in \$(ls -1 "\$parent" 2>/dev/null); do
  i=\$((i + 1))
  if [ "\$i" -le "\$remove_count" ]; then
    rm -rf "\$parent/\$d"
    echo "Pruned backup: \$parent/\$d"
  fi
done
EOF
      )
      ssh_base_cmd "sh -lc $(printf "%q" "${prune_script}")"
    fi
  fi
}

sync_files() {
  local rel
  case "${COMPONENT}" in
    theme)
      rel="wp-content/themes/"
      ;;
    plugins)
      rel="wp-content/plugins/"
      ;;
    upload)
      rel="wp-content/uploads/"
      ;;
    all)
      rel="wp-content/"
      ;;
    *)
      echo "[ERROR] invalid file component: ${COMPONENT}"
      exit 1
      ;;
  esac

  local src_path dst_path
  if [[ "${SRC_ENV}" == "prod" ]]; then
    src_path="${PROD_HOST}:${PROD_PATH}/${rel}"
    dst_path="${LOCAL_PATH}/${rel}"
    mkdir -p "${dst_path}"
  else
    src_path="${LOCAL_PATH}/${rel}"
    dst_path="${PROD_HOST}:${PROD_PATH}/${rel}"
  fi

  rsync_with_ssh "${src_path}" "${dst_path}"
  echo "File sync completed (${COMPONENT}: ${SRC_ENV} -> ${DST_ENV})"
}

ensure_base_commands
confirm_push
warn_backup_dir_visibility

# Entrypoint: DB-only, files-only, or DB+files.
if [[ "${COMPONENT}" == "db" ]]; then
  sync_db
elif [[ "${COMPONENT}" == "all" ]]; then
  sync_db
  sync_files
else
  sync_files
fi

echo "Finished: ${SRC_ENV} -> ${DST_ENV} (${COMPONENT})"
