#!/bin/bash
# =============================================================
# user-data.sh - Novatrix AB, AWS v44
# Kors som root forsta gangen webbservern startar.
# Som v43 (webbsidan hamtas fran privat S3 via rollen
# novatrix-web-role), plus HTTPS med ett sjalvsignerat cert
# eftersom port 443 nu ar oppen i security group och NACL.
# __BUCKET__ fylls i av deploy.sh.
# Logg: /var/log/cloud-init-output.log
# =============================================================
BUCKET="__BUCKET__"
export AWS_DEFAULT_REGION="eu-north-1"

# 1. Installera Apache med TLS-modul.
#    Allt gar over HTTPS (443), den enda utgaende porten som ar oppen.
dnf update -y
dnf install -y httpd mod_ssl openssl

# 2. Sjalvsignerat certifikat pa sokvagarna som ssl.conf anvander som standard.
#    Ett riktigt cert kraver ett domannamn (t.ex. ACM + load balancer senare).
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -subj "/CN=novatrix-web-v44/O=Novatrix AB" \
  -keyout /etc/pki/tls/private/localhost.key \
  -out /etc/pki/tls/certs/localhost.crt
chmod 600 /etc/pki/tls/private/localhost.key
systemctl enable --now httpd

# 3. Hamta webbsidan fran S3 (forsok igen tills rollens credentials finns)
for i in $(seq 1 10); do
  aws s3 cp "s3://${BUCKET}/webb/index.html" /var/www/html/index.html && break
  sleep 5
done

# 4. Synka webbsidan fran S3 varje minut (systemd-timer, samma som v43)
cat > /etc/systemd/system/novatrix-sync.service <<EOF
[Unit]
Description=Hamta Novatrix webbsida fran S3
[Service]
Type=oneshot
Environment=AWS_DEFAULT_REGION=eu-north-1
ExecStart=/usr/bin/aws s3 cp s3://${BUCKET}/webb/index.html /var/www/html/index.html
EOF
cat > /etc/systemd/system/novatrix-sync.timer <<EOF
[Unit]
Description=Synka Novatrix webbsida varje minut
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now novatrix-sync.timer

# 5. Liten statussida som visar var servern star i natet
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
md() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
MAC=$(md mac)
{
  echo "Novatrix webbserver v44, startad $(date '+%Y-%m-%d %H:%M')"
  echo "Privat IP:  $(md local-ipv4)"
  echo "Subnat:     $(md network/interfaces/macs/${MAC}/subnet-id) ($(md network/interfaces/macs/${MAC}/subnet-ipv4-cidr-block))"
  echo "VPC:        $(md network/interfaces/macs/${MAC}/vpc-id)"
  echo "AZ:         $(md placement/availability-zone)"
} > /var/www/html/natverk.txt
