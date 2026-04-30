#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage() {
  cat <<'EOF'
Usage:
  backup-wordpress.sh --stack <webinoly|tino> --domain <domain> [options]

Options:
  --stack <name>           webinoly or tino (required)
  --domain <domain>        source domain (required)
  --slug <path>            docroot slug, default: htdocs (webinoly), public_html (tino)
  --backup-root <path>     default: /root/wp-migration-backups
  --maintenance            enable wp maintenance mode during backup
  -h, --help               show help

Outputs:
  BACKUP_ARCHIVE=<absolute_path_to_tgz>
  BACKUP_SHA256=<sha256_hex>
EOF
}

STACK=""
DOMAIN=""
SLUG=""
BACKUP_ROOT="/root/wp-migration-backups"
USE_MAINTENANCE=0

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
    --slug)
      SLUG="${2:-}"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="${2:-}"
      shift 2
      ;;
    --maintenance)
      USE_MAINTENANCE=1
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

if [[ -z "$STACK" || -z "$DOMAIN" ]]; then
  usage
  exit 1
fi

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
  *)
    echo "Unsupported stack: $STACK (must be webinoly|tino)" >&2
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

for cmd in wp tar sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done

wp_config_path="$(find_wp_config || true)"
if [[ ! -d "$WP_PATH" || -z "$wp_config_path" ]]; then
  echo "WordPress path not found or invalid: $WP_PATH" >&2
  echo "Expected wp-config.php at $WP_PATH/wp-config.php or $(dirname "$WP_PATH")/wp-config.php" >&2
  exit 1
fi

mkdir -p "$BACKUP_ROOT"
log "Backup root: $BACKUP_ROOT"
log "WordPress path: $WP_PATH"
log "WordPress config: $wp_config_path"

timestamp="$(date +%Y%m%d-%H%M%S)"
base_name="${DOMAIN}-${timestamp}"
work_dir="$BACKUP_ROOT/$base_name"
archive_path="$BACKUP_ROOT/$base_name.tgz"
sha_path="$archive_path.sha256"

cleanup() {
  if [[ -d "$work_dir" ]]; then
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT

mkdir -p "$work_dir"

if [[ "$USE_MAINTENANCE" -eq 1 ]]; then
  log "Activating maintenance mode"
  wp --allow-root --path="$WP_PATH" maintenance-mode activate || true
fi

db_export="$work_dir/db.sql"
files_archive="$work_dir/files.tar.gz"
meta_file="$work_dir/meta.env"

log "Exporting database"
wp --allow-root --path="$WP_PATH" db export "$db_export" --add-drop-table --quiet

log "Archiving WordPress files"
tar -C "$WP_PATH" \
  --exclude='./wp-content/cache' \
  --exclude='./wp-content/ai1wm-backups' \
  -czf "$files_archive" .

source_siteurl="$(wp --allow-root --path="$WP_PATH" option get siteurl --quiet || true)"
source_home="$(wp --allow-root --path="$WP_PATH" option get home --quiet || true)"
source_prefix="$(wp --allow-root --path="$WP_PATH" config get table_prefix --quiet || true)"
php_version="$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"

cat > "$meta_file" <<EOF
SOURCE_STACK=$STACK
SOURCE_DOMAIN=$DOMAIN
SOURCE_SLUG=$SLUG
SOURCE_WP_PATH=$WP_PATH
SOURCE_WP_CONFIG_PATH=$wp_config_path
SOURCE_SITEURL=$source_siteurl
SOURCE_HOME=$source_home
SOURCE_TABLE_PREFIX=$source_prefix
PHP_VERSION=$php_version
BACKUP_CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

if [[ "$USE_MAINTENANCE" -eq 1 ]]; then
  log "Deactivating maintenance mode"
  wp --allow-root --path="$WP_PATH" maintenance-mode deactivate || true
fi

log "Packing final artifact"
tar -C "$BACKUP_ROOT" -czf "$archive_path" "$base_name"
sha_value="$(sha256sum "$archive_path" | awk '{print $1}')"
printf '%s  %s\n' "$sha_value" "$(basename "$archive_path")" > "$sha_path"

echo "Backup created: $archive_path"
echo "SHA256: $sha_value"
echo "BACKUP_ARCHIVE=$archive_path"
echo "BACKUP_SHA256=$sha_value"
