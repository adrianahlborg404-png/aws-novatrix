#!/bin/bash
# =============================================================
# user-data.sh - Novatrix AB, AWS v45
# Kors som root forsta gangen webbservern startar.
#   1. Apache, PHP och verktyg
#   2. EFS monteras pa wp-content (delad lagring)
#   3. WordPress laddas ner
#   4. wp-config.php skrivs med losenordet fran Secrets Manager
#   5. Nattlig backup av databasen till S3
# __VARIABLER__ fylls i av deploy.sh.
# Logg: /var/log/cloud-init-output.log
# =============================================================
set -euo pipefail
EFS_ID="__EFS_ID__"
DB_HOST="__DB_HOST__"
SECRET_ARN="__SECRET_ARN__"
BACKUP_BUCKET="__BACKUP_BUCKET__"
export AWS_DEFAULT_REGION="eu-north-1"
WEBB=/var/www/html

# ---------- 1. Paket ----------
# Bara HTTPS (443) ar oppet ut, och dnf anvander HTTPS.
dnf install -y httpd mod_ssl openssl php php-fpm php-mysqlnd php-gd php-mbstring php-xml \
  mariadb105 amazon-efs-utils jq

# Sjalvsignerat certifikat for HTTPS, som i v44
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -subj "/CN=novatrix-web-v45/O=Novatrix AB" \
  -keyout /etc/pki/tls/private/localhost.key \
  -out /etc/pki/tls/certs/localhost.crt
chmod 600 /etc/pki/tls/private/localhost.key

# ---------- 2. EFS pa wp-content, aven efter omstart ----------
# tls = krypterat aven pa vagen (stunnel), noresvport = klarar att
# anslutningen byts utan att monteringen hanger sig.
mkdir -p "$WEBB/wp-content"
echo "${EFS_ID}:/ $WEBB/wp-content efs _netdev,noresvport,tls 0 0" >> /etc/fstab
# Mount targets DNS-namn kan ta en stund att bli klart, forsok igen
for i in $(seq 1 20); do
  mount -a && mountpoint -q "$WEBB/wp-content" && break
  echo "EFS inte klar an (forsok $i), vantar 15 s"; sleep 15
done
mountpoint -q "$WEBB/wp-content"

# ---------- 3. WordPress ----------
# cp -n skriver inte over filer som redan finns pa EFS, sa en ny
# webbserver tar over teman, plugins och bilder fran den gamla.
cd /tmp
curl -sSLo wordpress.tar.gz https://wordpress.org/latest.tar.gz
tar -xzf wordpress.tar.gz
cp -rn /tmp/wordpress/. "$WEBB/"
rm -rf /tmp/wordpress /tmp/wordpress.tar.gz

# ---------- 4. wp-config.php fran Secrets Manager ----------
# Losenordet loggas aldrig och finns bara i wp-config.php (las bara for apache).
cat > /etc/novatrix.conf <<EOF
DB_HOST="$DB_HOST"
SECRET_ARN="$SECRET_ARN"
BACKUP_BUCKET="$BACKUP_BUCKET"
EOF
chmod 600 /etc/novatrix.conf

HEMLIGHET=""
for i in $(seq 1 10); do   # rollens credentials kan droja nagra sekunder
  HEMLIGHET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
    --query SecretString --output text 2>/dev/null) && break
  sleep 5
done
[ -n "$HEMLIGHET" ] || { echo "FEL: kunde inte lasa hemligheten i Secrets Manager"; exit 1; }
DB_USER=$(jq -r .username <<<"$HEMLIGHET")
DB_PASS=$(jq -r .password <<<"$HEMLIGHET")
salt() { openssl rand -base64 48 | tr -d '\n'; }

cat > "$WEBB/wp-config.php" <<EOF
<?php
// Skapad av user-data.sh (v45). Losenordet kommer fran AWS Secrets Manager.
define( 'DB_NAME',     'wordpress' );
define( 'DB_USER',     '$DB_USER' );
define( 'DB_PASSWORD', '$DB_PASS' );
define( 'DB_HOST',     '$DB_HOST' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  '' );

define( 'AUTH_KEY',         '$(salt)' );
define( 'SECURE_AUTH_KEY',  '$(salt)' );
define( 'LOGGED_IN_KEY',    '$(salt)' );
define( 'NONCE_KEY',        '$(salt)' );
define( 'AUTH_SALT',        '$(salt)' );
define( 'SECURE_AUTH_SALT', '$(salt)' );
define( 'LOGGED_IN_SALT',   '$(salt)' );
define( 'NONCE_SALT',       '$(salt)' );

\$table_prefix = 'wp_';

// Den publika IP:n byts nar instansen ersatts. Anvand adressen som
// besokaren skrev i webblasaren, i stallet for en sparad adress.
if ( ! empty( \$_SERVER['HTTP_HOST'] ) ) {
  \$schema = ( ! empty( \$_SERVER['HTTPS'] ) && \$_SERVER['HTTPS'] !== 'off' ) ? 'https' : 'http';
  define( 'WP_HOME',    \$schema . '://' . \$_SERVER['HTTP_HOST'] );
  define( 'WP_SITEURL', \$schema . '://' . \$_SERVER['HTTP_HOST'] );
}
define( 'FS_METHOD', 'direct' );
define( 'WP_DEBUG', false );

if ( ! defined( 'ABSPATH' ) ) {
  define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOF
unset HEMLIGHET DB_PASS
chown -R apache:apache "$WEBB"
chmod 640 "$WEBB/wp-config.php"

# ---------- 5. Backup av databasen till S3 ----------
# novatrix-mysql: kor mysql eller mysqldump mot RDS med inloggningen
# fran Secrets Manager, i en tillfallig fil som bara root kan lasa.
cat > /usr/local/bin/novatrix-mysql <<'EOF'
#!/bin/bash
# Anvandning: sudo /usr/local/bin/novatrix-mysql mysql -e "SHOW TABLES" wordpress
#             sudo /usr/local/bin/novatrix-mysql mysqldump wordpress
set -euo pipefail
source /etc/novatrix.conf
export AWS_DEFAULT_REGION="eu-north-1"
H=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)
CNF=$(mktemp); chmod 600 "$CNF"; trap 'rm -f "$CNF"' EXIT
printf '[client]\nhost=%s\nuser=%s\npassword=%s\n' \
  "$DB_HOST" "$(jq -r .username <<<"$H")" "$(jq -r .password <<<"$H")" > "$CNF"
VERKTYG="$1"; shift
"$VERKTYG" --defaults-extra-file="$CNF" "$@"
EOF

cat > /usr/local/bin/novatrix-backup <<'EOF'
#!/bin/bash
# Dumpar WordPress-databasen, packar den och laddar upp till S3.
# Livscykelregeln i S3 tar bort filer under backup/ efter 14 dagar.
set -euo pipefail
source /etc/novatrix.conf
export AWS_DEFAULT_REGION="eu-north-1"
FIL="wordpress-$(date -u +%Y%m%d-%H%M%S).sql.gz"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
/usr/local/bin/novatrix-mysql mysqldump --single-transaction --routines --triggers wordpress | gzip > "$TMP/$FIL"
aws s3 cp "$TMP/$FIL" "s3://${BACKUP_BUCKET}/backup/${FIL}" --only-show-errors
echo "Backup klar: s3://${BACKUP_BUCKET}/backup/${FIL} ($(du -h "$TMP/$FIL" | cut -f1))"
EOF
chmod 700 /usr/local/bin/novatrix-mysql /usr/local/bin/novatrix-backup

cat > /etc/systemd/system/novatrix-backup.service <<'EOF'
[Unit]
Description=Backup av Novatrix WordPress-databas till S3
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/novatrix-backup
EOF
cat > /etc/systemd/system/novatrix-backup.timer <<'EOF'
[Unit]
Description=Backup av databasen varje natt kl 02:00 svensk tid
[Timer]
OnCalendar=*-*-* 02:00:00 Europe/Stockholm
Persistent=true
[Install]
WantedBy=timers.target
EOF

# ---------- Starta ----------
systemctl daemon-reload
systemctl enable --now php-fpm httpd novatrix-backup.timer
echo "Novatrix v45: WordPress klar, oppna http://<publik-ip> och kor installationen"
