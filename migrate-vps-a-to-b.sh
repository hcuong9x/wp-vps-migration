#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  migrate-vps-a-to-b.sh [options]

Required:
  --source-host <host_or_ip>
  --target-host <host_or_ip>
  --source-domain <domain_on_vps_a>

Options:
  --config <file>                  load variables from config file (default: ./migrate.env if exists)
  --run-on-target                  run script on VPS B and copy directly A -> B via scp
  --target-domain <domain_on_vps_b> default: same as source-domain
  --source-stack <webinoly|tino>   default: webinoly
  --target-stack <webinoly|tino>   default: webinoly
  --source-slug <path>             default: htdocs/webinoly, public_html/tino
  --target-slug <path>             default: htdocs/webinoly, public_html/tino
  --target-url <url>               default: https://<target-domain>
  --source-backup-root <path>      default: /root/wp-migration-backups
  --target-incoming-dir <path>     default: /root/wp-migration-backups/incoming
  --ssh-user <user>                default: root
  --ssh-opts "<opts>"              default: -o StrictHostKeyChecking=accept-new
  --source-maintenance             put source site in maintenance mode while backup
  --target-maintenance             put target site in maintenance mode while restore
  --delete-source-artifact         remove backup artifact on VPS A after migration
  -h, --help

Notes:
  Run this script from a machine that can SSH to both VPS A and VPS B.
EOF
}

SOURCE_HOST=""
TARGET_HOST=""
SOURCE_DOMAIN=""
TARGET_DOMAIN=""
SOURCE_STACK="webinoly"
TARGET_STACK="webinoly"
SOURCE_SLUG=""
TARGET_SLUG=""
TARGET_URL=""
SOURCE_BACKUP_ROOT="/root/wp-migration-backups"
TARGET_INCOMING_DIR="/root/wp-migration-backups/incoming"
SSH_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=accept-new"
SOURCE_MAINTENANCE=0
TARGET_MAINTENANCE=0
DELETE_SOURCE_ARTIFACT=0
RUN_ON_TARGET=0
CONFIG_FILE=""

# Optional config from --config <file> or default ./migrate.env
default_config_file="./migrate.env"
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "$arg" == "--config" ]]; then
    next=$((i + 1))
    if [[ $next -gt $# ]]; then
      echo "Missing value for --config" >&2
      exit 1
    fi
    CONFIG_FILE="${!next}"
    break
  fi
done

if [[ -z "$CONFIG_FILE" && -f "$default_config_file" ]]; then
  CONFIG_FILE="$default_config_file"
fi

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --run-on-target)
      RUN_ON_TARGET=1
      shift
      ;;
    --source-host)
      SOURCE_HOST="${2:-}"
      shift 2
      ;;
    --target-host)
      TARGET_HOST="${2:-}"
      shift 2
      ;;
    --source-domain)
      SOURCE_DOMAIN="${2:-}"
      shift 2
      ;;
    --target-domain)
      TARGET_DOMAIN="${2:-}"
      shift 2
      ;;
    --source-stack)
      SOURCE_STACK="${2:-}"
      shift 2
      ;;
    --target-stack)
      TARGET_STACK="${2:-}"
      shift 2
      ;;
    --source-slug)
      SOURCE_SLUG="${2:-}"
      shift 2
      ;;
    --target-slug)
      TARGET_SLUG="${2:-}"
      shift 2
      ;;
    --target-url)
      TARGET_URL="${2:-}"
      shift 2
      ;;
    --source-backup-root)
      SOURCE_BACKUP_ROOT="${2:-}"
      shift 2
      ;;
    --target-incoming-dir)
      TARGET_INCOMING_DIR="${2:-}"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="${2:-}"
      shift 2
      ;;
    --ssh-opts)
      SSH_OPTS="${2:-}"
      shift 2
      ;;
    --source-maintenance)
      SOURCE_MAINTENANCE=1
      shift
      ;;
    --target-maintenance)
      TARGET_MAINTENANCE=1
      shift
      ;;
    --delete-source-artifact)
      DELETE_SOURCE_ARTIFACT=1
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

if [[ -z "$SOURCE_HOST" || -z "$TARGET_HOST" || -z "$SOURCE_DOMAIN" ]]; then
  usage
  exit 1
fi

if [[ -z "$TARGET_DOMAIN" ]]; then
  TARGET_DOMAIN="$SOURCE_DOMAIN"
fi

if [[ -z "$TARGET_URL" ]]; then
  TARGET_URL="https://$TARGET_DOMAIN"
fi

script_dir="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
backup_script="$script_dir/backup-wordpress.sh"
restore_script="$script_dir/restore-wordpress.sh"

if [[ ! -f "$backup_script" || ! -f "$restore_script" ]]; then
  echo "Missing backup/restore scripts in $script_dir" >&2
  exit 1
fi

if [[ "$RUN_ON_TARGET" -eq 1 ]] && ! command -v scp >/dev/null 2>&1; then
  echo "Missing required command for --run-on-target: scp" >&2
  exit 1
fi

ssh_args=()
# shellcheck disable=SC2206
ssh_args=($SSH_OPTS)

run_ssh_source() {
  ssh "${ssh_args[@]}" "${SSH_USER}@${SOURCE_HOST}" "$@"
}

run_ssh_target() {
  ssh "${ssh_args[@]}" "${SSH_USER}@${TARGET_HOST}" "$@"
}

log "Step 1/4: Run backup on VPS A ($SOURCE_HOST)"
backup_cmd=(bash -s -- --stack "$SOURCE_STACK" --domain "$SOURCE_DOMAIN" --backup-root "$SOURCE_BACKUP_ROOT")
if [[ -n "$SOURCE_SLUG" ]]; then
  backup_cmd+=(--slug "$SOURCE_SLUG")
fi
if [[ "$SOURCE_MAINTENANCE" -eq 1 ]]; then
  backup_cmd+=(--maintenance)
fi

backup_log="$(mktemp "${TMPDIR:-/tmp}/wp-backup-log.XXXXXX")"
run_ssh_source "${backup_cmd[@]}" < "$backup_script" | tee "$backup_log"

backup_archive="$(awk -F= '/^BACKUP_ARCHIVE=/{print $2}' "$backup_log" | tail -n1)"
backup_sha="$(awk -F= '/^BACKUP_SHA256=/{print $2}' "$backup_log" | tail -n1)"
rm -f "$backup_log"

if [[ -z "$backup_archive" || -z "$backup_sha" ]]; then
  echo "Failed to read backup output from VPS A" >&2
  exit 1
fi

target_archive="$TARGET_INCOMING_DIR/$(basename "$backup_archive")"

log "Step 2/4: Transfer archive to VPS B ($TARGET_HOST)"
if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
  mkdir -p "$TARGET_INCOMING_DIR"
else
  run_ssh_target "mkdir -p '$TARGET_INCOMING_DIR'"
fi

source_size="$(run_ssh_source "stat -c %s '$backup_archive' 2>/dev/null || stat -f %z '$backup_archive' 2>/dev/null || true" | tr -d '[:space:]')"
if [[ "$source_size" =~ ^[0-9]+$ ]]; then
  if command -v numfmt >/dev/null 2>&1; then
    log "Archive size: $(numfmt --to=iec --suffix=B "$source_size") ($source_size bytes)"
  else
    log "Archive size: $source_size bytes"
  fi
fi

if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
  log "Transfer mode: direct scp A -> B (running on target)"
  scp "${ssh_args[@]}" "${SSH_USER}@${SOURCE_HOST}:${backup_archive}" "$target_archive"
else
  if command -v pv >/dev/null 2>&1; then
    log "Transfer mode: pv progress"
    if [[ "$source_size" =~ ^[0-9]+$ ]]; then
      run_ssh_source "cat '$backup_archive'" | pv -p -t -e -r -b -s "$source_size" | run_ssh_target "cat > '$target_archive'"
    else
      run_ssh_source "cat '$backup_archive'" | pv -p -t -e -r -b | run_ssh_target "cat > '$target_archive'"
    fi
  elif dd if=/dev/null of=/dev/null bs=1 count=0 status=progress >/dev/null 2>&1; then
    log "Transfer mode: dd status=progress (pv not found)"
    run_ssh_source "cat '$backup_archive'" | dd bs=4M status=progress | run_ssh_target "cat > '$target_archive'"
  else
    log "Transfer mode: plain stream (no pv/dd progress available)"
    run_ssh_source "cat '$backup_archive'" | run_ssh_target "cat > '$target_archive'"
  fi
fi

log "Step 3/4: Verify checksum on VPS B"
if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
  target_sha="$(sha256sum "$target_archive" | awk '{print $1}')"
else
  target_sha="$(run_ssh_target "sha256sum '$target_archive' | awk '{print \$1}'")"
fi
if [[ "$backup_sha" != "$target_sha" ]]; then
  echo "Checksum mismatch: source=$backup_sha target=$target_sha" >&2
  exit 1
fi
log "Checksum OK: $target_sha"

log "Step 4/4: Restore on VPS B"
restore_cmd=(bash -s -- --stack "$TARGET_STACK" --domain "$TARGET_DOMAIN" --backup "$target_archive" --source-domain "$SOURCE_DOMAIN" --target-url "$TARGET_URL")
if [[ -n "$TARGET_SLUG" ]]; then
  restore_cmd+=(--slug "$TARGET_SLUG")
fi
if [[ "$TARGET_MAINTENANCE" -eq 1 ]]; then
  restore_cmd+=(--maintenance)
fi

restore_log="$(mktemp "${TMPDIR:-/tmp}/wp-restore-log.XXXXXX")"
if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
  bash "$restore_script" "${restore_cmd[@]:3}" | tee "$restore_log"
else
  run_ssh_target "${restore_cmd[@]}" < "$restore_script" | tee "$restore_log"
fi
if ! grep -q '^RESTORE_DONE=1$' "$restore_log"; then
  echo "Restore may be incomplete: RESTORE_DONE marker not found" >&2
  rm -f "$restore_log"
  exit 1
fi
rm -f "$restore_log"

if [[ "$DELETE_SOURCE_ARTIFACT" -eq 1 ]]; then
  run_ssh_source "rm -f '$backup_archive' '$backup_archive.sha256'"
  log "Deleted source backup artifact on VPS A"
fi

log "Migration completed"
echo "Source: $SOURCE_HOST ($SOURCE_DOMAIN)"
echo "Target: $TARGET_HOST ($TARGET_DOMAIN)"
echo "Target archive: $target_archive"
