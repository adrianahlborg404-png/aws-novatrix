#!/bin/bash
# =============================================================
# user-data.sh - Novatrix AB, AWS v43
# Kors som root forsta gangen instansen startar.
# Webbsidan hamtas nu fran en privat S3-bucket via instansens
# IAM-roll (novatrix-web-role), inte fran GitHub. Inga nycklar
# finns pa servern, rollen ger tillfalliga credentials.
# __BUCKET__ fylls i av deploy.sh.
# Logg: /var/log/cloud-init-output.log
# =============================================================
BUCKET="__BUCKET__"
export AWS_DEFAULT_REGION="eu-north-1"

# 1. Installera och starta Apache
dnf update -y
dnf install -y httpd
systemctl enable --now httpd

# 2. Hamta webbsidan fran S3 (forsok igen tills rollens credentials finns)
for i in $(seq 1 10); do
  aws s3 cp "s3://${BUCKET}/webb/index.html" /var/www/html/index.html && break
  sleep 5
done

# 3. Synka webbsidan fran S3 varje minut (systemd-timer)
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

# 4. Testa rollens behorigheter och publicera resultatet (konto-ID maskeras)
testa() { if "$@" >/dev/null 2>&1; then echo "TILLATET"; else echo "NEKAT"; fi; }
{
  echo "IAM-test fran EC2-instansen, $(date '+%Y-%m-%d %H:%M')"
  echo "Identitet: $(aws sts get-caller-identity --query Arn --output text)"
  echo ""
  echo "Lasa webb/index.html i S3   (forvantat TILLATET): $(testa aws s3 cp "s3://${BUCKET}/webb/index.html" /tmp/test.html)"
  echo "Skriva till webb/ i S3      (forvantat NEKAT):    $(testa aws s3 cp /etc/hostname "s3://${BUCKET}/webb/hack.txt")"
  echo "Lista alla S3-buckets       (forvantat NEKAT):    $(testa aws s3api list-buckets)"
  echo "Lista EC2-instanser         (forvantat NEKAT):    $(testa aws ec2 describe-instances)"
  echo "Lista IAM-anvandare         (forvantat NEKAT):    $(testa aws iam list-users)"
} | sed 's/[0-9]\{12\}/<konto-id>/g' > /var/www/html/iam-test.txt
