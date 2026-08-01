#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  restore-wordpress.sh --stack <webinoly|tino|wptangtoc-ols> --domain <target-domain> --backup <archive.tgz> [options]

Options:
  --stack <name>            webinoly, tino, or wptangtoc-ols (required)
  --domain <domain>         target domain on VPS B (required)
  --backup <path>           backup archive path on VPS B (required)
  --source-domain <domain>  override source domain (default from backup metadata)
  --target-url <url>        default: https://<target-domain>
  --slug <path>             docroot slug, default: htdocs (webinoly), public_html (tino), html (wptangtoc-ols)
  --db-name <name>          target DB name (optional, auto-detect from current wp-config if omitted)
  --db-user <name>          target DB user
  --db-pass <password>      target DB password
  --db-host <host>          target DB host
  --owner-group <u:g>       chown target files, default: current owner of docroot
  --maintenance             enable wp maintenance mode during restore
  --keep-workdir            keep extracted temp directory
  -h, --help                show help

Output:
  RESTORE_DONE=1
EOF
}

STACK=""
DOMAIN=""
BACKUP_ARCHIVE=""
SOURCE_DOMAIN_OVERRIDE=""
TARGET_URL=""
SLUG=""
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
DB_HOST="${DB_HOST:-}"
OWNER_GROUP=""
USE_MAINTENANCE=0
KEEP_WORKDIR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)
      STACK="${2:-}"
      shift 2
      ;;
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --backup)
      BACKUP_ARCHIVE="${2:-}"
      shift 2
      ;;
    --source-domain)
      SOURCE_DOMAIN_OVERRIDE="${2:-}"
      shift 2
      ;;
    --target-url)
      TARGET_URL="${2:-}"
      shift 2
      ;;
    --slug)
      SLUG="${2:-}"
      shift 2
      ;;
    --db-name)
      DB_NAME="${2:-}"
      shift 2
      ;;
    --db-user)
      DB_USER="${2:-}"
      shift 2
      ;;
    --db-pass)
      DB_PASS="${2:-}"
      shift 2
      ;;
    --db-host)
      DB_HOST="${2:-}"
      shift 2
      ;;
    --owner-group)
      OWNER_GROUP="${2:-}"
      shift 2
      ;;
    --maintenance)
      USE_MAINTENANCE=1
      shift
      ;;
    --keep-workdir)
      KEEP_WORKDIR=1
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

if [[ -z "$STACK" || -z "$DOMAIN" || -z "$BACKUP_ARCHIVE" ]]; then
  usage
  exit 1
fi

stack_key="$(printf '%s' "$STACK" | tr '[:upper:]' '[:lower:]')"
stack_key="${stack_key// /-}"
stack_key="${stack_key//_/-}"
if [[ "$stack_key" == "wptangtocols" ]]; then
  stack_key="wptangtoc-ols"
fi
STACK="$stack_key"

case "$STACK" in
  webinoly)
    if [[ -z "$SLUG" ]]; then
      SLUG="htdocs"
    fi
    WP_PATH="/var/www/$DOMAIN/$SLUG"
    ;;
  tino)
    if [[ -z "$SLUG" ]]; then
      SLUG="public_html"
    fi
    WP_PATH="/home/$DOMAIN/$SLUG"
    ;;
  wptangtoc-ols)
    if [[ -z "$SLUG" ]]; then
      SLUG="html"
    fi
    WP_PATH="/home/$DOMAIN/$SLUG"
    ;;
  *)
    echo "Unsupported stack: $STACK (must be webinoly|tino|wptangtoc-ols)" >&2
    exit 1
    ;;
esac

find_wp_config() {
  if [[ -f "$WP_PATH/wp-config.php" ]]; then
    printf '%s\n' "$WP_PATH/wp-config.php"
    return 0
  fi

  parent_path="$(dirname "$WP_PATH")/wp-config.php"
  if [[ -f "$parent_path" ]]; then
    printf '%s\n' "$parent_path"
    return 0
  fi

  return 1
}

for cmd in wp tar find stat; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

if [[ ! -d "$WP_PATH" ]]; then
  echo "Target WordPress path does not exist: $WP_PATH" >&2
  exit 1
fi

if [[ ! -f "$BACKUP_ARCHIVE" ]]; then
  echo "Backup archive not found: $BACKUP_ARCHIVE" >&2
  exit 1
fi

log "Target WordPress path: $WP_PATH"
log "Backup archive: $BACKUP_ARCHIVE"
wp_config_path="$(find_wp_config || true)"
if [[ -n "$wp_config_path" ]]; then
  log "Target WordPress config: $wp_config_path"
fi

if [[ -z "$TARGET_URL" ]]; then
  TARGET_URL="https://$DOMAIN"
fi

if [[ -z "$OWNER_GROUP" ]]; then
  OWNER_GROUP="$(stat -c "%U:%G" "$WP_PATH")"
fi

if [[ -n "$wp_config_path" ]]; then
  if [[ -z "$DB_NAME" ]]; then
    DB_NAME="$(wp --allow-root --path="$WP_PATH" config get DB_NAME --quiet || true)"
  fi
  if [[ -z "$DB_USER" ]]; then
    DB_USER="$(wp --allow-root --path="$WP_PATH" config get DB_USER --quiet || true)"
  fi
  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(wp --allow-root --path="$WP_PATH" config get DB_PASSWORD --quiet || true)"
  fi
  if [[ -z "$DB_HOST" ]]; then
    DB_HOST="$(wp --allow-root --path="$WP_PATH" config get DB_HOST --quiet || true)"
  fi
fi

if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_HOST" ]]; then
  echo "Target DB credentials incomplete." >&2
  echo "Auto-detect reads DB_NAME/DB_USER/DB_PASSWORD/DB_HOST from:" >&2
  echo "  - $WP_PATH/wp-config.php" >&2
  echo "  - $(dirname "$WP_PATH")/wp-config.php" >&2
  echo "If that file does not exist or cannot be read, provide --db-name --db-user --db-pass --db-host." >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/wp-restore.XXXXXX)"
cleanup() {
  if [[ "$KEEP_WORKDIR" -eq 0 && -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

tar -xzf "$BACKUP_ARCHIVE" -C "$tmp_dir"
payload_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"

if [[ -z "$payload_dir" || ! -f "$payload_dir/files.tar.gz" || ! -f "$payload_dir/db.sql" ]]; then
  echo "Invalid backup archive format: $BACKUP_ARCHIVE" >&2
  exit 1
fi

source_domain=""
source_siteurl=""
source_home=""
if [[ -f "$payload_dir/meta.env" ]]; then
  # shellcheck disable=SC1090
  source "$payload_dir/meta.env"
  source_domain="${SOURCE_DOMAIN:-}"
  source_siteurl="${SOURCE_SITEURL:-}"
  source_home="${SOURCE_HOME:-}"
fi

if [[ -n "$SOURCE_DOMAIN_OVERRIDE" ]]; then
  source_domain="$SOURCE_DOMAIN_OVERRIDE"
fi

if [[ "$USE_MAINTENANCE" -eq 1 && -n "$wp_config_path" ]]; then
  log "Activating maintenance mode"
  wp --allow-root --path="$WP_PATH" maintenance-mode activate || true
fi

# Guard before deleting any existing content.
if [[ "$WP_PATH" == "/" || "$WP_PATH" == "/var/www" || "$WP_PATH" == "/home" ]]; then
  echo "Unsafe target path: $WP_PATH" >&2
  exit 1
fi

shopt -s dotglob nullglob
for item in "$WP_PATH"/*; do
  if [[ "$(basename "$item")" == ".well-known" ]]; then
    continue
  fi
  rm -rf -- "$item"
done
shopt -u dotglob nullglob

log "Extracting WordPress files"
tar -xzf "$payload_dir/files.tar.gz" -C "$WP_PATH"

log "Fixing ownership before running WP-CLI (extracted files keep source VPS's UID/GID; a mismatch vs the process owner makes WordPress fall back to the ftpext filesystem method and crash on the next full WP bootstrap)"
chown -R "$OWNER_GROUP" "$WP_PATH"

wp_config_path="$(find_wp_config || true)"
if [[ -z "$wp_config_path" ]]; then
  echo "No wp-config.php found after extracting files." >&2
  echo "Expected wp-config.php at $WP_PATH/wp-config.php or $(dirname "$WP_PATH")/wp-config.php" >&2
  exit 1
fi
log "Using WordPress config: $wp_config_path"

log "Updating target DB config in wp-config.php"
wp --allow-root --path="$WP_PATH" config set DB_NAME "$DB_NAME" --type=constant
wp --allow-root --path="$WP_PATH" config set DB_USER "$DB_USER" --type=constant
wp --allow-root --path="$WP_PATH" config set DB_PASSWORD "$DB_PASS" --type=constant
wp --allow-root --path="$WP_PATH" config set DB_HOST "$DB_HOST" --type=constant

log "Resetting and importing database"
wp --allow-root --path="$WP_PATH" db check --quiet
wp --allow-root --path="$WP_PATH" db reset --yes --quiet
wp --allow-root --path="$WP_PATH" db import "$payload_dir/db.sql" --quiet

if [[ -n "$source_siteurl" ]]; then
  wp --allow-root --path="$WP_PATH" search-replace "$source_siteurl" "$TARGET_URL" --all-tables --precise --skip-columns=guid --quiet || true
fi
if [[ -n "$source_home" && "$source_home" != "$source_siteurl" ]]; then
  wp --allow-root --path="$WP_PATH" search-replace "$source_home" "$TARGET_URL" --all-tables --precise --skip-columns=guid --quiet || true
fi
if [[ -n "$source_domain" && "$source_domain" != "$DOMAIN" ]]; then
  wp --allow-root --path="$WP_PATH" search-replace "$source_domain" "$DOMAIN" --all-tables --precise --skip-columns=guid --quiet || true
fi

wp --allow-root --path="$WP_PATH" option update siteurl "$TARGET_URL" --quiet
wp --allow-root --path="$WP_PATH" option update home "$TARGET_URL" --quiet

log "Applying ownership and permissions"
chown -R "$OWNER_GROUP" "$WP_PATH"
find "$WP_PATH" -type d -exec chmod 755 {} +
find "$WP_PATH" -type f -exec chmod 644 {} +
if [[ "$wp_config_path" == "$WP_PATH/wp-config.php" ]]; then
  chmod 640 "$wp_config_path"
fi

wp --allow-root --path="$WP_PATH" cache flush >/dev/null 2>&1 || true

if [[ "$USE_MAINTENANCE" -eq 1 ]]; then
  log "Deactivating maintenance mode"
  wp --allow-root --path="$WP_PATH" maintenance-mode deactivate || true
fi

echo "Restore completed at: $WP_PATH"
echo "Target URL: $TARGET_URL"
echo "RESTORE_DONE=1"
