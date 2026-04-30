# WordPress Migration A -> B (Tino/Webinoly)

## Muc tieu
- Backup website WordPress tu VPS A.
- Chuyen artifact qua VPS B bang SSH.
- Restore tren VPS B, cap nhat domain/URL, fix permission.

Truong hop pho bien: chuyen VPS nhung giu nguyen domain. Khi do `SOURCE_DOMAIN` va `TARGET_DOMAIN` co the giong nhau.

Bo script nay tham khao y tuong tu `another-app/301-website/run.sh` va `another-app/301-webinoly/run.sh`, nhung doi qua huong **server-level migration** de phu hop cho cross-VPS.

## File
- `backup-wordpress.sh`: chay tren VPS A, tao 1 file `.tgz` (files + db + metadata).
- `restore-wordpress.sh`: chay tren VPS B, giai nen va restore DB/files.
- `migrate-vps-a-to-b.sh`: script dieu phoi tu may trung gian co SSH root vao ca A va B.
- `migrate.env.example`: mau file cau hinh de tranh phai export nhieu bien.

## Path mac dinh theo stack
- `webinoly`: `/var/www/<domain>/htdocs`
- `tino`: `/home/<domain>/public_html`

Voi Webinoly, `wp-config.php` co the nam ngoai docroot o `/var/www/<domain>/wp-config.php`.
Script se tu tim config trong ca docroot va thu muc cha cua docroot.

Neu site dung slug khac, truyen them `--source-slug` hoac `--target-slug`.

## Dieu kien can
- Quyen `root` SSH vao VPS A va VPS B.
- Tren ca 2 VPS da co: `bash`, `wp`, `tar`, `mysql`, `sha256sum`.
- VPS B da co site/domain duoc tao truoc (docroot ton tai).
- DB cua site tren VPS B nen duoc tao truoc (thuong da co neu ban tao site WordPress bang script cua Webinoly/Tino).
- Nen tao snapshot VPS truoc khi restore.
- Khuyen nghi cai `pv` tren may dieu phoi de xem progress transfer ro hon (neu khong co, script fallback sang `dd status=progress` neu ho tro).

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

## Cach khuyen nghi cho ban: SSH vao VPS B roi chay (copy truc tiep A -> B)
1) SSH vao VPS B:
```bash
ssh root@<TARGET_HOST>
```

2) Tren VPS B:
```bash
cd /path/to/wp-vps-migration
cp migrate.env.example migrate.env
nano migrate.env
```
Dat them:
```bash
RUN_ON_TARGET=1
```

3) Chay migrate:
```bash
./migrate-vps-a-to-b.sh --source-maintenance --target-maintenance --run-on-target
```

Mode `run-on-target` se:
- Step 1: backup tren VPS A (qua SSH).
- Step 2: `scp` truc tiep tu A ve B (khong qua may local).
- Step 3: verify checksum tren B.
- Step 4: restore local tren B.

Trong luc chay, script se hien thi:
- log realtime cho backup/restore (khong doi toi luc xong moi in).
- transfer mode (`direct scp` hoac `pv progress` hoac `dd status=progress` hoac `plain stream`).
- kich thuoc archive va checksum verify.

## Playbook test chi tiet (vao may nao, chay lenh gi)
Luu y:
- Co 3 "noi" tham gia: may dieu phoi (local/WSL), VPS A (source), VPS B (target).
- Khuyen nghi test truoc voi domain staging tren VPS B.
- Cac lenh ben duoi la cho shell `bash` (Linux/WSL/Git-Bash).

### B1) Tren may dieu phoi: tao 1 file config (gon hon export)
```bash
cd /path/to/wp-vps-migration
chmod +x *.sh

cp migrate.env.example migrate.env
nano migrate.env
source ./migrate.env
```

Case chuyen cung 1 domain:
```bash
SOURCE_DOMAIN=example.com
TARGET_DOMAIN=example.com
```
Hoac bo trong `TARGET_DOMAIN`, script se tu dong lay bang `SOURCE_DOMAIN`.

Neu khong muon `source`, script tu dong nap `./migrate.env` neu file ton tai.

Neu can SSH key rieng, sua truc tiep trong `migrate.env`:
```bash
SSH_OPTS='-i ~/.ssh/id_rsa -o StrictHostKeyChecking=accept-new'
```

### B2) Tren may dieu phoi: precheck nhanh VPS A/B qua SSH
```bash
ssh $SSH_USER@$SOURCE_HOST "hostname; command -v wp tar sha256sum"
ssh $SSH_USER@$TARGET_HOST "hostname; command -v wp tar sha256sum"
```

Neu stack la `webinoly`:
```bash
ssh $SSH_USER@$SOURCE_HOST "test -f /var/www/$SOURCE_DOMAIN/htdocs/wp-config.php && echo SRC_OK"
ssh $SSH_USER@$TARGET_HOST "test -d /var/www/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/htdocs && echo TGT_OK"
```

Neu stack la `tino`:
```bash
ssh $SSH_USER@$SOURCE_HOST "test -f /home/$SOURCE_DOMAIN/public_html/wp-config.php && echo SRC_OK"
ssh $SSH_USER@$TARGET_HOST "test -d /home/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/public_html && echo TGT_OK"
```

### B3) Tren may dieu phoi: test backup rieng (chua restore)
```bash
ssh $SSH_USER@$SOURCE_HOST "bash -s -- --stack $SOURCE_STACK --domain $SOURCE_DOMAIN --maintenance" < backup-wordpress.sh | tee ./wp-backup.out
```

Kiem tra ket qua backup:
```bash
grep '^BACKUP_ARCHIVE=' ./wp-backup.out
grep '^BACKUP_SHA256=' ./wp-backup.out
```

### B4) Tren may dieu phoi: chay full migrate A -> B
```bash
./migrate-vps-a-to-b.sh \
  --source-maintenance \
  --target-maintenance
```

Neu ban khong dat `migrate.env`, co the truyen full option 1 dong:
```bash
./migrate-vps-a-to-b.sh --source-host 1.2.3.4 --target-host 5.6.7.8 --source-domain oldsite.com --target-domain staging-newsite.com --source-stack webinoly --target-stack webinoly --source-maintenance --target-maintenance
```

Neu dang SSH vao VPS B va muon copy truc tiep A -> B:
```bash
./migrate-vps-a-to-b.sh --run-on-target --source-maintenance --target-maintenance
```

### B5) Tren VPS B: verify sau restore
Neu `webinoly`:
```bash
ssh $SSH_USER@$TARGET_HOST "wp --allow-root --path=/var/www/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/htdocs option get siteurl"
ssh $SSH_USER@$TARGET_HOST "wp --allow-root --path=/var/www/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/htdocs option get home"
ssh $SSH_USER@$TARGET_HOST "wp --allow-root --path=/var/www/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/htdocs core is-installed && echo WP_OK"
```

Neu `tino`:
```bash
ssh $SSH_USER@$TARGET_HOST "wp --allow-root --path=/home/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/public_html option get siteurl"
ssh $SSH_USER@$TARGET_HOST "wp --allow-root --path=/home/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/public_html option get home"
ssh $SSH_USER@$TARGET_HOST "wp --allow-root --path=/home/${TARGET_DOMAIN:-$SOURCE_DOMAIN}/public_html core is-installed && echo WP_OK"
```

Test them tu may ban:
```bash
curl -I "https://${TARGET_DOMAIN:-$SOURCE_DOMAIN}"
```

Neu ban chua doi DNS, lenh `curl` tren co the van vao VPS A cu. Co 2 cach test dung VPS B:
```bash
curl -I --resolve "${TARGET_DOMAIN:-$SOURCE_DOMAIN}:443:$TARGET_HOST" "https://${TARGET_DOMAIN:-$SOURCE_DOMAIN}"
```
hoac sua tam file hosts tren may ban tro domain ve IP VPS B.

### B6) Neu can rollback nhanh khi test fail
- Cach nhanh nhat: restore lai tu snapshot VPS B (neu da chup truoc do).
- Hoac dung mot backup cu cua site dich roi chay lai `restore-wordpress.sh` vao domain dich.

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
  - Neu chay qua `migrate-vps-a-to-b.sh`, dung `--target-db-name ... --target-db-user ... --target-db-pass ... --target-db-host ...`
  - Hoac dien trong `migrate.env`: `TARGET_DB_NAME`, `TARGET_DB_USER`, `TARGET_DB_PASS`, `TARGET_DB_HOST`.
- Sau restore, script chay `search-replace` de doi domain va cap nhat `siteurl/home`.

## Goi y quy trinh an toan production
1. Snapshot VPS A/B truoc thao tac.
2. Chay migrate vao domain staging tren B.
3. Verify wp-admin, plugin, media, permalink, cron.
4. Chuyen DNS/SSL khi da test xong.
