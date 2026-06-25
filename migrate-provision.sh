#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <domain1> [domain2 ...]"
  exit 1
fi

rand_alnum() { (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"); }
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

ADMIN_EMAIL="heworld39@gmail.com"
TOTAL=$#
IDX=0

for DOMAIN in "$@"; do
  IDX=$((IDX + 1))
  echo ""
  echo "========================================"
  log "[$IDX/$TOTAL] $DOMAIN — start"
  echo "========================================"

  WP_PATH="/var/www/$DOMAIN/htdocs"
  ADMIN_PASS="$(rand_alnum 16)"

  log "[$IDX/$TOTAL] $DOMAIN — create site (webinoly)"
  site "$DOMAIN" -wp

  log "[$IDX/$TOTAL] $DOMAIN — install WordPress"
  wp core install \
    --url="https://$DOMAIN" \
    --title="${DOMAIN%%.*}" \
    --admin_user="admin" \
    --admin_password="$ADMIN_PASS" \
    --admin_email="$ADMIN_EMAIL" \
    --skip-email \
    --path="$WP_PATH" \
    --allow-root

  log "[$IDX/$TOTAL] $DOMAIN — disable httpauth, enable SSL"
  httpauth "$DOMAIN" -wp-admin=off
  site "$DOMAIN" -ssl=on

  log "[$IDX/$TOTAL] $DOMAIN — migrate from VPS A"
  /opt/wp-vps-migration/migrate-vps-a-to-b.sh \
    --source-domain "$DOMAIN" \
    --target-domain "$DOMAIN" \
    --run-on-target \
    --source-maintenance \
    --target-maintenance

  log "[$IDX/$TOTAL] $DOMAIN — reload PHP-FPM"
  systemctl reload php8.4-fpm

  log "[$IDX/$TOTAL] $DOMAIN — done"
done

echo ""
log "All $TOTAL domain(s) migrated successfully"
