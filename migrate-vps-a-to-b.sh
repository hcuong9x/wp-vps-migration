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
  one of:
    --source-domain <domain_on_vps_a>
    --domains "<domain1,domain2,...>"
    --site <source_domain[=target_domain]>  (repeatable)

Options:
  --config <file>                  load variables from config file (default: ./migrate.env if exists)
  --run-on-target                  run script on VPS B and copy directly A -> B via scp
  --source-key-only                do not allow password prompt for SOURCE SSH (force batch mode)
  --allow-source-password          allow password prompt for SOURCE SSH
  --source-domains "<domains>"      comma/space separated source domains
  --target-domains "<domains>"      comma/space separated target domains; count must match source domains
  --target-domain <domain_on_vps_b> default: same as source-domain (single-site only)
  --source-stack <webinoly|tino|wptangtoc-ols>   default: webinoly
  --target-stack <webinoly|tino|wptangtoc-ols>   default: webinoly
  --source-slug <path>             default: htdocs (webinoly), public_html (tino), html (wptangtoc-ols)
  --target-slug <path>             default: htdocs (webinoly), public_html (tino), html (wptangtoc-ols)
  --target-url <url>               default: https://<target-domain>
  --target-db-name <name>          target DB name if auto-detect from wp-config.php fails
  --target-db-user <name>          target DB user
  --target-db-pass <password>      target DB password
  --target-db-host <host>          target DB host
  --source-backup-root <path>      default: /root/wp-migration-backups
  --target-incoming-dir <path>     default: /root/wp-migration-backups/incoming
  --ssh-user <user>                default: root
  --ssh-opts "<opts>"              default: -o StrictHostKeyChecking=accept-new
  --source-ssh-opts "<opts>"       SOURCE SSH options (default: SSH_OPTS)
  --target-ssh-opts "<opts>"       TARGET SSH options (default: SSH_OPTS)
  --source-maintenance             put source site in maintenance mode while backup
  --target-maintenance             put target site in maintenance mode while restore
  --delete-source-artifact         remove backup artifact on VPS A after transfer/checksum (default)
  --keep-source-artifact           keep backup artifact on VPS A
  --delete-target-archive          remove incoming archive on VPS B after successful restore (default)
  --keep-target-archive            keep incoming archive on VPS B
  -h, --help

Notes:
  Run this script from a machine that can SSH to both VPS A and VPS B.
  For same-domain batch migration, use:
    migrate-vps-a-to-b.sh --domains "site1.com,site2.com" --run-on-target
  For renamed targets, use:
    migrate-vps-a-to-b.sh --site old1.com=new1.com --site old2.com=new2.com
EOF
}

SOURCE_HOST=""
TARGET_HOST=""
SOURCE_DOMAIN=""
TARGET_DOMAIN=""
SOURCE_DOMAINS=""
TARGET_DOMAINS=""
SITE_PAIRS=""
SOURCE_STACK="webinoly"
TARGET_STACK="webinoly"
SOURCE_SLUG=""
TARGET_SLUG=""
TARGET_URL=""
TARGET_DB_NAME=""
TARGET_DB_USER=""
TARGET_DB_PASS=""
TARGET_DB_HOST=""
SOURCE_BACKUP_ROOT="/root/wp-migration-backups"
TARGET_INCOMING_DIR="/root/wp-migration-backups/incoming"
SSH_USER="root"
SSH_OPTS="-o StrictHostKeyChecking=accept-new"
SOURCE_SSH_OPTS=""
TARGET_SSH_OPTS=""
SOURCE_MAINTENANCE=0
TARGET_MAINTENANCE=0
DELETE_SOURCE_ARTIFACT=1
DELETE_TARGET_ARCHIVE=1
RUN_ON_TARGET=0
SOURCE_KEY_ONLY=""
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

CLI_SOURCE_DOMAIN_VALUES=()
CLI_TARGET_DOMAIN_VALUES=()
CLI_SITE_SPECS=()

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
    --source-key-only)
      SOURCE_KEY_ONLY=1
      shift
      ;;
    --allow-source-password)
      SOURCE_KEY_ONLY=0
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
      CLI_SOURCE_DOMAIN_VALUES+=("${2:-}")
      shift 2
      ;;
    --source-domains|--domains)
      SOURCE_DOMAINS="${2:-}"
      CLI_SOURCE_DOMAIN_VALUES+=("${2:-}")
      shift 2
      ;;
    --target-domain)
      TARGET_DOMAIN="${2:-}"
      CLI_TARGET_DOMAIN_VALUES+=("${2:-}")
      shift 2
      ;;
    --target-domains)
      TARGET_DOMAINS="${2:-}"
      CLI_TARGET_DOMAIN_VALUES+=("${2:-}")
      shift 2
      ;;
    --site|--domain-pair)
      CLI_SITE_SPECS+=("${2:-}")
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
    --target-db-name)
      TARGET_DB_NAME="${2:-}"
      shift 2
      ;;
    --target-db-user)
      TARGET_DB_USER="${2:-}"
      shift 2
      ;;
    --target-db-pass)
      TARGET_DB_PASS="${2:-}"
      shift 2
      ;;
    --target-db-host)
      TARGET_DB_HOST="${2:-}"
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
    --source-ssh-opts)
      SOURCE_SSH_OPTS="${2:-}"
      shift 2
      ;;
    --target-ssh-opts)
      TARGET_SSH_OPTS="${2:-}"
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
    --keep-source-artifact)
      DELETE_SOURCE_ARTIFACT=0
      shift
      ;;
    --delete-target-archive)
      DELETE_TARGET_ARCHIVE=1
      shift
      ;;
    --keep-target-archive)
      DELETE_TARGET_ARCHIVE=0
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

split_list_values() {
  local value item
  for value in "$@"; do
    value="${value//,/ }"
    value="${value//$'\n'/ }"
    for item in $value; do
      if [[ -n "$item" ]]; then
        printf '%s\n' "$item"
      fi
    done
  done
}

SOURCE_SITES=()
TARGET_SITES=()
SITE_SPECS=()

add_split_values() {
  local destination="$1"
  shift
  local item
  while IFS= read -r item; do
    case "$destination" in
      source)
        SOURCE_SITES+=("$item")
        ;;
      target)
        TARGET_SITES+=("$item")
        ;;
      site)
        SITE_SPECS+=("$item")
        ;;
      *)
        echo "Internal error: unknown list destination: $destination" >&2
        exit 1
        ;;
    esac
  done < <(split_list_values "$@")
}

build_site_lists() {
  local source_from_config_domains=0
  local spec source target

  if [[ ${#CLI_SITE_SPECS[@]} -gt 0 ]]; then
    add_split_values site "${CLI_SITE_SPECS[@]}"
  elif [[ ${#CLI_SOURCE_DOMAIN_VALUES[@]} -gt 0 || ${#CLI_TARGET_DOMAIN_VALUES[@]} -gt 0 ]]; then
    add_split_values source "${CLI_SOURCE_DOMAIN_VALUES[@]}"
    if [[ ${#CLI_TARGET_DOMAIN_VALUES[@]} -gt 0 ]]; then
      add_split_values target "${CLI_TARGET_DOMAIN_VALUES[@]}"
    elif [[ ${#SOURCE_SITES[@]} -eq 1 && -n "$TARGET_DOMAIN" ]]; then
      TARGET_SITES+=("$TARGET_DOMAIN")
    fi
  elif [[ -n "$SITE_PAIRS" ]]; then
    add_split_values site "$SITE_PAIRS"
  else
    if [[ -n "$SOURCE_DOMAINS" ]]; then
      add_split_values source "$SOURCE_DOMAINS"
      source_from_config_domains=1
    elif [[ -n "$SOURCE_DOMAIN" ]]; then
      SOURCE_SITES+=("$SOURCE_DOMAIN")
    fi

    if [[ -n "$TARGET_DOMAINS" ]]; then
      add_split_values target "$TARGET_DOMAINS"
    elif [[ -n "$TARGET_DOMAIN" ]]; then
      if [[ "$source_from_config_domains" -eq 1 && ${#SOURCE_SITES[@]} -gt 1 ]]; then
        echo "TARGET_DOMAIN is single-site only when SOURCE_DOMAINS has multiple entries." >&2
        echo "Use TARGET_DOMAINS with the same count, or leave TARGET_DOMAIN empty to keep the same domains." >&2
        exit 1
      fi
      TARGET_SITES+=("$TARGET_DOMAIN")
    fi
  fi

  if [[ ${#SITE_SPECS[@]} -gt 0 ]]; then
    for spec in "${SITE_SPECS[@]}"; do
      if [[ "$spec" == *"="* ]]; then
        source="${spec%%=*}"
        target="${spec#*=}"
      else
        source="$spec"
        target="$spec"
      fi

      if [[ -z "$source" || -z "$target" ]]; then
        echo "Invalid --site value: $spec" >&2
        echo "Expected: source-domain or source-domain=target-domain" >&2
        exit 1
      fi

      SOURCE_SITES+=("$source")
      TARGET_SITES+=("$target")
    done
  fi

  if [[ ${#SOURCE_SITES[@]} -eq 0 ]]; then
    usage
    exit 1
  fi

  if [[ ${#TARGET_SITES[@]} -eq 0 ]]; then
    TARGET_SITES=("${SOURCE_SITES[@]}")
  fi

  if [[ ${#SOURCE_SITES[@]} -ne ${#TARGET_SITES[@]} ]]; then
    echo "Source/target domain count mismatch: ${#SOURCE_SITES[@]} source, ${#TARGET_SITES[@]} target." >&2
    echo "Use --target-domains with the same count, or omit targets to keep the same domains." >&2
    exit 1
  fi
}

build_site_lists

if [[ -z "$SOURCE_HOST" || -z "$TARGET_HOST" ]]; then
  usage
  exit 1
fi

SITE_COUNT="${#SOURCE_SITES[@]}"

if [[ "$SITE_COUNT" -gt 1 && -n "$TARGET_URL" ]]; then
  echo "TARGET_URL is single-site only." >&2
  echo "For batch migration, leave TARGET_URL empty so each site defaults to https://<target-domain>." >&2
  exit 1
fi

if [[ "$SITE_COUNT" -gt 1 && ( -n "$TARGET_DB_NAME" || -n "$TARGET_DB_USER" || -n "$TARGET_DB_PASS" || -n "$TARGET_DB_HOST" ) ]]; then
  echo "Global TARGET_DB_* values are unsafe for batch migration." >&2
  echo "Leave them empty so restore auto-detects each target site's wp-config.php, or migrate those sites one by one." >&2
  exit 1
fi

if [[ -z "$SOURCE_SSH_OPTS" ]]; then
  SOURCE_SSH_OPTS="$SSH_OPTS"
fi

if [[ -z "$TARGET_SSH_OPTS" ]]; then
  TARGET_SSH_OPTS="$SSH_OPTS"
fi

# Default behavior:
# - run-on-target: enforce key auth for SOURCE to avoid hidden password prompts.
# - non run-on-target: keep backward-compatible (allow password prompts).
if [[ -z "$SOURCE_KEY_ONLY" ]]; then
  if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
    SOURCE_KEY_ONLY=1
  else
    SOURCE_KEY_ONLY=0
  fi
fi

if [[ "$SOURCE_KEY_ONLY" -eq 1 ]]; then
  if [[ "$SOURCE_SSH_OPTS" != *"BatchMode="* ]]; then
    SOURCE_SSH_OPTS="$SOURCE_SSH_OPTS -o BatchMode=yes"
  fi
  if [[ "$SOURCE_SSH_OPTS" != *"PreferredAuthentications="* ]]; then
    SOURCE_SSH_OPTS="$SOURCE_SSH_OPTS -o PreferredAuthentications=publickey"
  fi
  if [[ "$SOURCE_SSH_OPTS" != *"PasswordAuthentication="* ]]; then
    SOURCE_SSH_OPTS="$SOURCE_SSH_OPTS -o PasswordAuthentication=no"
  fi
fi

normalize_stack() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value// /-}"
  value="${value//_/-}"
  if [[ "$value" == "wptangtocols" ]]; then
    value="wptangtoc-ols"
  fi
  printf '%s\n' "$value"
}

validate_stack() {
  local value="$1"
  local flag="$2"
  case "$value" in
    webinoly|tino|wptangtoc-ols)
      ;;
    *)
      echo "Unsupported stack for $flag: $value (must be webinoly|tino|wptangtoc-ols)" >&2
      exit 1
      ;;
  esac
}

SOURCE_STACK="$(normalize_stack "$SOURCE_STACK")"
TARGET_STACK="$(normalize_stack "$TARGET_STACK")"
validate_stack "$SOURCE_STACK" "--source-stack"
validate_stack "$TARGET_STACK" "--target-stack"

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

source_ssh_args=()
target_ssh_args=()
# shellcheck disable=SC2206
source_ssh_args=($SOURCE_SSH_OPTS)
# shellcheck disable=SC2206
target_ssh_args=($TARGET_SSH_OPTS)

run_ssh_source() {
  ssh "${source_ssh_args[@]}" "${SSH_USER}@${SOURCE_HOST}" "$@"
}

run_ssh_target() {
  ssh "${target_ssh_args[@]}" "${SSH_USER}@${TARGET_HOST}" "$@"
}

if [[ "$SOURCE_KEY_ONLY" -eq 1 ]]; then
  log "Preflight: checking key auth to SOURCE ($SOURCE_HOST)"
  if ! run_ssh_source "true" >/dev/null 2>&1; then
    echo "SOURCE key authentication failed (password prompt disabled)." >&2
    echo "Please setup SSH key from current machine to SOURCE, then retry." >&2
    echo "Example:" >&2
    echo "  ssh-keygen -t ed25519 -f ~/.ssh/wp_migrate -N ''" >&2
    echo "  ssh-copy-id -i ~/.ssh/wp_migrate.pub ${SSH_USER}@${SOURCE_HOST}" >&2
    echo "  Then set SOURCE_SSH_OPTS or SSH_OPTS with: -i ~/.ssh/wp_migrate -o IdentitiesOnly=yes" >&2
    exit 1
  fi
fi

migrate_site() {
  local source_domain="$1"
  local target_domain="$2"
  local site_index="$3"
  local site_total="$4"
  local target_url="$TARGET_URL"
  local backup_log backup_archive backup_sha target_archive source_size target_sha restore_log
  local -a backup_cmd restore_cmd

  if [[ -z "$target_url" ]]; then
    target_url="https://$target_domain"
  fi

  log "Migration $site_index/$site_total: $source_domain -> $target_domain"
  log "Step 1/4 [$site_index/$site_total]: Run backup on VPS A ($SOURCE_HOST)"
  backup_cmd=(bash -s -- --stack "$SOURCE_STACK" --domain "$source_domain" --backup-root "$SOURCE_BACKUP_ROOT")
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
    echo "Failed to read backup output from VPS A for $source_domain" >&2
    exit 1
  fi

  target_archive="$TARGET_INCOMING_DIR/$(basename "$backup_archive")"

  log "Step 2/4 [$site_index/$site_total]: Transfer archive to VPS B ($TARGET_HOST)"
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
    scp "${source_ssh_args[@]}" "${SSH_USER}@${SOURCE_HOST}:${backup_archive}" "$target_archive"
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

  log "Step 3/4 [$site_index/$site_total]: Verify checksum on VPS B"
  if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
    target_sha="$(sha256sum "$target_archive" | awk '{print $1}')"
  else
    target_sha="$(run_ssh_target "sha256sum '$target_archive' | awk '{print \$1}'")"
  fi
  if [[ "$backup_sha" != "$target_sha" ]]; then
    echo "Checksum mismatch for $source_domain: source=$backup_sha target=$target_sha" >&2
    exit 1
  fi
  log "Checksum OK: $target_sha"

  if [[ "$DELETE_SOURCE_ARTIFACT" -eq 1 ]]; then
    if run_ssh_source "rm -f '$backup_archive' '$backup_archive.sha256'"; then
      log "Deleted source backup artifact on VPS A"
    else
      log "WARN: cannot delete source backup artifact on VPS A"
    fi
  fi

  log "Step 4/4 [$site_index/$site_total]: Restore on VPS B"
  restore_cmd=(bash -s -- --stack "$TARGET_STACK" --domain "$target_domain" --backup "$target_archive" --source-domain "$source_domain" --target-url "$target_url")
  if [[ -n "$TARGET_SLUG" ]]; then
    restore_cmd+=(--slug "$TARGET_SLUG")
  fi
  if [[ "$TARGET_MAINTENANCE" -eq 1 ]]; then
    restore_cmd+=(--maintenance)
  fi
  if [[ -n "$TARGET_DB_NAME" ]]; then
    restore_cmd+=(--db-name "$TARGET_DB_NAME")
  fi
  if [[ -n "$TARGET_DB_USER" ]]; then
    restore_cmd+=(--db-user "$TARGET_DB_USER")
  fi
  if [[ -n "$TARGET_DB_PASS" ]]; then
    restore_cmd+=(--db-pass "$TARGET_DB_PASS")
  fi
  if [[ -n "$TARGET_DB_HOST" ]]; then
    restore_cmd+=(--db-host "$TARGET_DB_HOST")
  fi

  restore_log="$(mktemp "${TMPDIR:-/tmp}/wp-restore-log.XXXXXX")"
  if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
    bash "$restore_script" "${restore_cmd[@]:3}" | tee "$restore_log"
  else
    run_ssh_target "${restore_cmd[@]}" < "$restore_script" | tee "$restore_log"
  fi
  if ! grep -q '^RESTORE_DONE=1$' "$restore_log"; then
    echo "Restore may be incomplete for $target_domain: RESTORE_DONE marker not found" >&2
    rm -f "$restore_log"
    exit 1
  fi
  rm -f "$restore_log"

  if [[ "$DELETE_TARGET_ARCHIVE" -eq 1 ]]; then
    if [[ "$RUN_ON_TARGET" -eq 1 ]]; then
      if rm -f "$target_archive" "$target_archive.sha256"; then
        log "Deleted incoming archive on VPS B"
      else
        log "WARN: cannot delete incoming archive on VPS B"
      fi
    else
      if run_ssh_target "rm -f '$target_archive' '$target_archive.sha256'"; then
        log "Deleted incoming archive on VPS B"
      else
        log "WARN: cannot delete incoming archive on VPS B"
      fi
    fi
  fi

  log "Migration completed for $source_domain -> $target_domain"
  echo "Source: $SOURCE_HOST ($source_domain)"
  echo "Target: $TARGET_HOST ($target_domain)"
  echo "Target URL: $target_url"
  if [[ "$DELETE_SOURCE_ARTIFACT" -eq 1 ]]; then
    echo "Source artifact: cleanup attempted for $backup_archive"
  else
    echo "Source artifact: kept at $backup_archive"
  fi
  if [[ "$DELETE_TARGET_ARCHIVE" -eq 1 ]]; then
    echo "Target archive: cleaned from $target_archive"
  else
    echo "Target archive: $target_archive"
  fi
}

for ((site_index = 0; site_index < SITE_COUNT; site_index++)); do
  migrate_site "${SOURCE_SITES[$site_index]}" "${TARGET_SITES[$site_index]}" "$((site_index + 1))" "$SITE_COUNT"
done

log "All migrations completed ($SITE_COUNT site(s))"
