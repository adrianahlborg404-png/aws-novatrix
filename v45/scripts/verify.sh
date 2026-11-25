#!/bin/bash
# =============================================================
# verify.sh - Novatrix AB, AWS v45
# Visar att WordPress fungerar mot databasen och EFS, att datat
# inte ar exponerat och att backuperna ar uppsatta:
#   1. WordPress fran internet
#   2. Databasen (RDS): privat, krypterad, automatisk backup
#   3. Delad lagring (EFS)
#   4. Objektlagring (S3): privat, livscykelregel 14 dagar
#   5. Inifran via bastion: montering, tabeller, backup och vem
#      som nar databasen
#
#   bash verify.sh
#
# TILLATET = TCP-anslutningen gick fram
# BLOCKERAT = timeout, paketet slangdes av NACL eller security group
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")" || exit 1

NAT_STACK="novatrix-natverk-v44"
DATA_STACK="novatrix-data-v45"
KEY_FIL="$(pwd)/novatrix-v45-key.pem"

ut() { aws cloudformation describe-stacks --stack-name "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null; }
DB_ID=$(ut "$DATA_STACK" DbInstanceId)
[ -n "$DB_ID" ] && [ "$DB_ID" != "None" ] || { echo "Stacken $DATA_STACK saknas. Kor deploy.sh forst."; exit 1; }
DB_HOST=$(ut "$DATA_STACK" DbEndpoint);  EFS_ID=$(ut "$DATA_STACK" FileSystemId)
BUCKET=$(ut "$DATA_STACK" BackupBucket); EFS_SG=$(ut "$DATA_STACK" EfsSgId)
WEB_SG=$(ut "$NAT_STACK" WebSgId);       DB_SG=$(ut "$NAT_STACK" DbSgId)
BASTION_SG=$(ut "$NAT_STACK" BastionSgId); MGMT_NACL=$(ut "$NAT_STACK" MgmtNaclId)
DB_PORT=$(ut "$NAT_STACK" DbPort)
ADMIN_IP=$(ut "$NAT_STACK" AdminIp)

instans() {  # namn falt
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$2" --output text
}
WEB_IP=$(instans novatrix-web-v45 PublicIpAddress)
WEB_PRIV=$(instans novatrix-web-v45 PrivateIpAddress)
WEB_AZ=$(instans novatrix-web-v45 Placement.AvailabilityZone)
BASTION_IP=$(instans novatrix-bastion-v45 PublicIpAddress)
[ "$WEB_IP" != "None" ] && [ "$BASTION_IP" != "None" ] || { echo "Instanserna kor inte. Kor deploy.sh."; exit 1; }
CS_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
# EFS mount target i samma AZ som webbservern
EFS_IP=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query "MountTargets[?AvailabilityZoneName=='$WEB_AZ'].IpAddress | [0]" --output text)

# ---------- hjalpfunktioner (samma som v44) ----------
OK=0; FEL=0
resultat() {  # beskrivning forvantat faktiskt
  local s="OK"
  if [ "$2" = "$3" ]; then OK=$((OK+1)); else s="FEL"; FEL=$((FEL+1)); fi
  printf "  %-52s forvantat %-9s fick %-9s [%s]\n" "$1" "$2" "$3" "$s"
}
TCP_TEST='t(){ out=$(timeout 4 bash -c "</dev/tcp/$1/$2" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo TILLATET; elif [ $rc -eq 124 ]; then echo BLOCKERAT
  elif [[ $out == *refused* ]]; then echo STANGD; else echo BLOCKERAT; fi; }; t'
tcp() { bash -c "$TCP_TEST \"\$@\"" _ "$1" "$2"; }
jn() { [ "$1" = "$2" ] && echo JA || echo NEJ; }   # jamfor -> JA/NEJ

SSH_OPT=(-i "$KEY_FIL" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes)
pa_bastion() { ssh "${SSH_OPT[@]}" "ec2-user@$BASTION_IP" "$@"; }
pa_webb() { ssh "${SSH_OPT[@]}" -o ProxyCommand="ssh ${SSH_OPT[*]} -W %h:%p ec2-user@$BASTION_IP" \
  "ec2-user@$WEB_PRIV" "$@"; }

CS_OPPEN=0
stang_cloudshell() {
  aws ec2 revoke-security-group-ingress --group-id "$BASTION_SG" \
    --protocol tcp --port 22 --cidr "${CS_IP}/32" >/dev/null 2>&1
  aws ec2 delete-network-acl-entry --network-acl-id "$MGMT_NACL" --ingress --rule-number 90 >/dev/null 2>&1
  aws ec2 delete-network-acl-entry --network-acl-id "$MGMT_NACL" --egress  --rule-number 90 >/dev/null 2>&1
  CS_OPPEN=0
}
trap '[ "$CS_OPPEN" = 1 ] && stang_cloudshell && echo "==> Tillfallig SSH-atkomst for CloudShell borttagen"' EXIT

echo "Novatrix v45 - verifiering av WordPress-stacken, $(date '+%Y-%m-%d %H:%M')"
echo "Webb $WEB_IP ($WEB_PRIV, $WEB_AZ) | Bastion $BASTION_IP | CloudShell $CS_IP"

echo ""
echo "    Vantar pa att WordPress svarar (user data, max 6 min)..."
for _ in $(seq 1 72); do
  [ "$(curl -skL -o /dev/null -w '%{http_code}' --max-time 6 "http://$WEB_IP/")" = 200 ] && break; sleep 5
done

# ---------- 1. WordPress ----------
echo ""
echo "==> 1/5 WordPress fran internet"
SIDA=$(curl -skL --max-time 10 "http://$WEB_IP/")
KOD=$(curl -skL -o /dev/null -w '%{http_code}' --max-time 10 "http://$WEB_IP/")
resultat "HTTP 80, WordPress svarar med 200"               200 "$KOD"
resultat "Sidan ar WordPress (wp-content/wp-includes)"     JA  "$(grep -qE 'wp-(content|includes|admin)' <<<"$SIDA" && echo JA || echo NEJ)"
resultat "Inget databasfel (Error establishing...)"        JA  "$(grep -q 'Error establishing a database connection' <<<"$SIDA" && echo NEJ || echo JA)"
resultat "HTTPS 443 (sjalvsignerat)"                       200 "$(curl -skL -o /dev/null -w '%{http_code}' --max-time 10 "https://$WEB_IP/")"
if grep -q 'install.php' <<<"$SIDA"; then
  echo "    OBS: WordPress ar inte installerad an. Oppna http://$WEB_IP och kor installationen."
fi

# ---------- 2. Databasen ----------
echo ""
echo "==> 2/5 Databasen (RDS $DB_ID)"
rds() { aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query "DBInstances[0].$1" --output text; }
resultat "Motor"                                           mariadb "$(rds Engine)"
resultat "Publikt atkomlig (PubliclyAccessible)"           False "$(rds PubliclyAccessible)"
resultat "Krypterad i vila (StorageEncrypted)"             True  "$(rds StorageEncrypted)"
resultat "Automatisk backup, dagar (BackupRetentionPeriod)" 1    "$(rds BackupRetentionPeriod)"
DB_IP=$(python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$DB_HOST" 2>/dev/null)
resultat "DNS-namnet pekar pa en privat IP ($DB_IP)"       JA  "$([[ "$DB_IP" =~ ^10\. ]] && echo JA || echo NEJ)"
resultat "MariaDB $DB_PORT fran internet (CloudShell)"     BLOCKERAT "$(tcp "$DB_HOST" "$DB_PORT")"
KALLOR=$(aws ec2 describe-security-groups --group-ids "$DB_SG" \
  --query "SecurityGroups[0].IpPermissions[].[join(',',IpRanges[].CidrIp), join(',',UserIdGroupPairs[].GroupId)]" \
  --output text | tr -s '\t\n' ' ' | xargs)
resultat "db-sg slapper bara in webb-sg"                   JA  "$(jn "$KALLOR" "$WEB_SG")"

# ---------- 3. EFS ----------
echo ""
echo "==> 3/5 Delad lagring (EFS $EFS_ID)"
resultat "Krypterad i vila"                                True "$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].Encrypted' --output text)"
resultat "Mount targets som ar 'available'"                2 "$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query "length(MountTargets[?LifeCycleState=='available'])" --output text)"
KALLOR=$(aws ec2 describe-security-groups --group-ids "$EFS_SG" \
  --query "SecurityGroups[0].IpPermissions[].[join(',',IpRanges[].CidrIp), join(',',UserIdGroupPairs[].GroupId)]" \
  --output text | tr -s '\t\n' ' ' | xargs)
resultat "efs-sg slapper bara in webb-sg"                  JA  "$(jn "$KALLOR" "$WEB_SG")"

# ---------- 4. S3 ----------
echo ""
echo "==> 4/5 Objektlagring (s3://novatrix-backup-<konto-id>)"
resultat "All publik atkomst blockerad"                    JA "$(jn "$(aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
  --output text | xargs)" "True True True True")"
resultat "Livscykelregel: backup/ tas bort efter, dagar"   14 "$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query "Rules[?Status=='Enabled'] | [0].Expiration.Days" --output text)"
resultat "Kryptering i vila"                               AES256 "$(aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"
# Med dina egna admin-rattigheter, men over okrypterad HTTP: bucket-policyn ska neka
resultat "Atkomst over HTTP utan TLS (som admin)"          NEKAD "$(aws s3api list-objects-v2 --bucket "$BUCKET" \
  --endpoint-url http://s3.eu-north-1.amazonaws.com --max-items 1 >/dev/null 2>&1 && echo TILLATEN || echo NEKAD)"

# ---------- 5. Inifran ----------
echo ""
echo "==> 5/5 Inifran, via bastion"
if [ "$CS_IP" != "$ADMIN_IP" ]; then
  echo "    Oppnar tillfalligt SSH till bastion for CloudShell ($CS_IP), stangs efter testet"
  CS_OPPEN=1
  aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" \
    --protocol tcp --port 22 --cidr "${CS_IP}/32" >/dev/null
  aws ec2 create-network-acl-entry --network-acl-id "$MGMT_NACL" --ingress --rule-number 90 \
    --protocol tcp --port-range From=22,To=22 --cidr-block "${CS_IP}/32" --rule-action allow
  aws ec2 create-network-acl-entry --network-acl-id "$MGMT_NACL" --egress --rule-number 90 \
    --protocol tcp --port-range From=1024,To=65535 --cidr-block "${CS_IP}/32" --rule-action allow
  for _ in 1 2 3 4 5 6; do [ "$(tcp "$BASTION_IP" 22)" = TILLATET ] && break; sleep 5; done
fi
if [ -f "$KEY_FIL" ]; then
  resultat "Webb: EFS monterad pa wp-content"              JA   "$(pa_webb 'mountpoint -q /var/www/html/wp-content && echo JA || echo NEJ')"
  resultat "Webb: filsystemstyp pa wp-content"             nfs4 "$(pa_webb 'findmnt -no FSTYPE /var/www/html/wp-content')"
  TABELLER=$(pa_webb "sudo /usr/local/bin/novatrix-mysql mysql -N -e 'SHOW TABLES' wordpress | wc -l")
  resultat "Webb: WordPress-tabeller i RDS ($TABELLER st)" JA   "$([ "${TABELLER:-0}" -gt 0 ] 2>/dev/null && echo JA || echo NEJ)"
  resultat "Webb -> databasen $DB_PORT"                    TILLATET  "$(pa_webb "$TCP_TEST $DB_HOST $DB_PORT")"
  resultat "Webb -> EFS 2049"                              TILLATET  "$(pa_webb "$TCP_TEST $EFS_IP 2049")"
  resultat "Bastion -> databasen $DB_PORT"                 BLOCKERAT "$(pa_bastion "$TCP_TEST $DB_HOST $DB_PORT")"
  resultat "Bastion -> EFS 2049"                           BLOCKERAT "$(pa_bastion "$TCP_TEST $EFS_IP 2049")"
  resultat "Webb: backup-timer aktiv (varje natt 02:00)"   enabled   "$(pa_webb 'systemctl is-enabled novatrix-backup.timer')"

  echo "    Kor en backup nu i stallet for att vanta till natten..."
  pa_webb 'sudo systemctl start novatrix-backup.service && sudo journalctl -u novatrix-backup -o cat | grep "Backup klar" | tail -1' | sed 's/^/    /'
  SENASTE=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix backup/ \
    --query 'sort_by(Contents,&LastModified)[-1].Key' --output text 2>/dev/null)
  resultat "Backup finns i S3 ($SENASTE)"                  JA "$([[ "$SENASTE" == backup/wordpress-*.sql.gz ]] && echo JA || echo NEJ)"
else
  echo "  Hoppar over: nyckeln $(basename "$KEY_FIL") saknas i den har mappen."
fi

echo ""
echo "==> Sammanfattning: ${OK} OK, ${FEL} FEL"
