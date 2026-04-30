#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  cleanup-migration-backups.sh --domain <domain> [options]

Options:
  --domain <domain>           domain prefix to clean, for example example.com
  --backup-root <path>        default: /root/wp-migration-backups
  --incoming-dir <path>       default: <backup-root>/incoming
  --keep-latest <count>       keep newest N .tgz files in each directory, default: 1
  --older-than-days <days>    only delete files older than N days
  --include-workdirs          also delete leftover unpacked work dirs matching the domain
  --yes                       actually delete files; without this, dry-run only
  -h, --help                  show help

Examples:
  cleanup-migration-backups.sh --domain example.com
  cleanup-migration-backups.sh --domain example.com --yes
  cleanup-migration-backups.sh --domain example.com --keep-latest 0 --yes
  cleanup-migration-backups.sh --domain example.com --older-than-days 7 --yes
EOF
}

DOMAIN=""
BACKUP_ROOT="/root/wp-migration-backups"
INCOMING_DIR=""
KEEP_LATEST=1
OLDER_THAN_DAYS=""
INCLUDE_WORKDIRS=0
CONFIRM_DELETE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="${2:-}"
      shift 2
      ;;
    --incoming-dir)
      INCOMING_DIR="${2:-}"
      shift 2
      ;;
    --keep-latest)
      KEEP_LATEST="${2:-}"
      shift 2
      ;;
    --older-than-days)
      OLDER_THAN_DAYS="${2:-}"
      shift 2
      ;;
    --include-workdirs)
      INCLUDE_WORKDIRS=1
      shift
      ;;
    --yes)
      CONFIRM_DELETE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DOMAIN" ]]; then
  usage
  exit 1
fi

if [[ "$DOMAIN" == -* || "$DOMAIN" == *[!A-Za-z0-9._-]* ]]; then
  echo "Unsafe domain value: $DOMAIN" >&2
  exit 1
fi

if [[ ! "$KEEP_LATEST" =~ ^[0-9]+$ ]]; then
  echo "--keep-latest must be a non-negative integer" >&2
  exit 1
fi

if [[ -n "$OLDER_THAN_DAYS" && ! "$OLDER_THAN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "--older-than-days must be a non-negative integer" >&2
  exit 1
fi

if [[ -z "$INCOMING_DIR" ]]; then
  INCOMING_DIR="$BACKUP_ROOT/incoming"
fi

is_unsafe_dir() {
  case "$1" in
    ""|"/"|"/root"|"/home"|"/var"|"/tmp"|"/usr"|"/opt")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if is_unsafe_dir "$BACKUP_ROOT" || is_unsafe_dir "$INCOMING_DIR"; then
  echo "Refusing to clean an unsafe backup directory." >&2
  echo "BACKUP_ROOT=$BACKUP_ROOT" >&2
  echo "INCOMING_DIR=$INCOMING_DIR" >&2
  exit 1
fi

now_epoch="$(date +%s)"
delete_count=0
skip_count=0

is_old_enough() {
  local path="$1"

  if [[ -z "$OLDER_THAN_DAYS" ]]; then
    return 0
  fi

  local mtime
  if ! mtime="$(stat -c %Y "$path" 2>/dev/null)"; then
    return 1
  fi

  (( now_epoch - mtime >= OLDER_THAN_DAYS * 86400 ))
}

queue_delete() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    return 0
  fi

  if ! is_old_enough "$path"; then
    log "SKIP not old enough: $path"
    skip_count=$((skip_count + 1))
    return 0
  fi

  if [[ "$CONFIRM_DELETE" -eq 1 ]]; then
    rm -rf -- "$path"
    log "DELETED: $path"
  else
    log "DRY-RUN delete: $path"
  fi
  delete_count=$((delete_count + 1))
}

clean_archives_in_dir() {
  local dir="$1"
  local label="$2"

  if [[ ! -d "$dir" ]]; then
    log "Skip missing $label directory: $dir"
    return 0
  fi

  local archives=()
  mapfile -d '' archives < <(find "$dir" -maxdepth 1 -type f -name "$DOMAIN-*.tgz" -print0 | sort -z)

  local total="${#archives[@]}"
  if (( total == 0 )); then
    log "No matching archives in $label: $dir"
    return 0
  fi

  log "Found $total archive(s) in $label: $dir"

  local to_delete=$((total - KEEP_LATEST))
  if (( to_delete <= 0 )); then
    log "Nothing to delete in $label; keep-latest=$KEEP_LATEST"
    return 0
  fi

  local i
  for ((i = 0; i < to_delete; i++)); do
    queue_delete "${archives[$i]}"
    queue_delete "${archives[$i]}.sha256"
  done
}

clean_workdirs_in_dir() {
  local dir="$1"
  local label="$2"

  if [[ "$INCLUDE_WORKDIRS" -ne 1 || ! -d "$dir" ]]; then
    return 0
  fi

  local workdirs=()
  mapfile -d '' workdirs < <(find "$dir" -maxdepth 1 -type d -name "$DOMAIN-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]" -print0 | sort -z)

  local total="${#workdirs[@]}"
  if (( total == 0 )); then
    log "No leftover work dirs in $label: $dir"
    return 0
  fi

  log "Found $total leftover work dir(s) in $label: $dir"

  local workdir
  for workdir in "${workdirs[@]}"; do
    queue_delete "$workdir"
  done
}

if [[ "$CONFIRM_DELETE" -eq 1 ]]; then
  log "Delete mode enabled"
else
  log "Dry-run mode; add --yes to delete"
fi

log "Domain: $DOMAIN"
log "Keep latest per directory: $KEEP_LATEST"
if [[ -n "$OLDER_THAN_DAYS" ]]; then
  log "Only delete items older than $OLDER_THAN_DAYS day(s)"
fi

clean_archives_in_dir "$BACKUP_ROOT" "backup-root"
clean_archives_in_dir "$INCOMING_DIR" "incoming"
clean_workdirs_in_dir "$BACKUP_ROOT" "backup-root"
clean_workdirs_in_dir "$INCOMING_DIR" "incoming"

if [[ "$CONFIRM_DELETE" -eq 1 ]]; then
  log "Deleted item count: $delete_count"
else
  log "Dry-run item count: $delete_count"
fi
log "Skipped item count: $skip_count"
