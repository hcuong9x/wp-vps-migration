# WordPress Migration A -> B (Tino/Webinoly)

## Muc tieu
- Backup website WordPress tu VPS A.
- Chuyen artifact qua VPS B bang SSH.
- Restore tren VPS B, cap nhat domain/URL, fix permission.

Bo script nay tham khao y tuong tu `another-app/301-website/run.sh` va `another-app/301-webinoly/run.sh`, nhung doi qua huong **server-level migration** de phu hop cho cross-VPS.

## File
- `backup-wordpress.sh`: chay tren VPS A, tao 1 file `.tgz` (files + db + metadata).
- `restore-wordpress.sh`: chay tren VPS B, giai nen va restore DB/files.
- `migrate-vps-a-to-b.sh`: script dieu phoi tu may trung gian co SSH root vao ca A va B.

## Path mac dinh theo stack
- `webinoly`: `/var/www/<domain>/htdocs`
- `tino`: `/home/<domain>/public_html`

Neu site dung slug khac, truyen them `--source-slug` hoac `--target-slug`.

## Dieu kien can
- Quyen `root` SSH vao VPS A va VPS B.
- Tren ca 2 VPS da co: `bash`, `wp`, `tar`, `mysql`, `sha256sum`.
- VPS B da co site/domain duoc tao truoc (docroot ton tai).
- DB cua site tren VPS B nen duoc tao truoc (thuong da co neu ban tao site WordPress bang script cua Webinoly/Tino).
- Nen tao snapshot VPS truoc khi restore.

## Cach chay nhanh (one-shot)
```bash
cd wp-vps-migration
chmod +x *.sh

./migrate-vps-a-to-b.sh \
  --source-host 1.2.3.4 \
  --target-host 5.6.7.8 \
  --source-domain oldsite.com \
  --target-domain newsite.com \
  --source-stack webinoly \
  --target-stack webinoly \
  --source-maintenance \
  --target-maintenance
```

## Chay tung buoc (thu cong)
1) Tren VPS A:
```bash
./backup-wordpress.sh --stack webinoly --domain oldsite.com --maintenance
```
Lay gia tri `BACKUP_ARCHIVE=...`.

2) Chuyen file sang VPS B:
```bash
ssh root@A "cat /root/wp-migration-backups/oldsite.com-YYYYmmdd-HHMMSS.tgz" \
  | ssh root@B "cat > /root/wp-migration-backups/incoming/oldsite.com.tgz"
```

3) Tren VPS B:
```bash
./restore-wordpress.sh \
  --stack webinoly \
  --domain newsite.com \
  --backup /root/wp-migration-backups/incoming/oldsite.com.tgz \
  --source-domain oldsite.com \
  --target-url https://newsite.com \
  --maintenance
```

## Luu y quan trong
- `restore-wordpress.sh` se xoa noi dung hien tai trong docroot dich (giu lai `.well-known`).
- Script se ghi de `DB_NAME/DB_USER/DB_PASSWORD/DB_HOST` trong `wp-config.php` cua site dich de tro toi DB dich.
- Neu auto-detect DB dich that bai, truyen tay:
  - `--db-name ... --db-user ... --db-pass ... --db-host ...`
- Sau restore, script chay `search-replace` de doi domain va cap nhat `siteurl/home`.

## Goi y quy trinh an toan production
1. Snapshot VPS A/B truoc thao tac.
2. Chay migrate vao domain staging tren B.
3. Verify wp-admin, plugin, media, permalink, cron.
4. Chuyen DNS/SSL khi da test xong.
