#!/bin/bash
# =============================================================
# verify.sh - Novatrix AB, AWS v46
# Visar att stacken blev som avsett:
#   1. Stackarna: status, drift (har nagon andrat i konsolen?)
#      och beroendena mellan dem (exports och imports)
#   2. WordPress fran internet
#   3. Databasen: privat, krypterad, automatisk backup
#   4. EFS och S3: krypterat, privat, livscykelregel
#   5. Inifran via bastion: montering, tabeller, backup och
#      vem som nar databasen och EFS
#
#   bash verify.sh
#   bash verify.sh -p ../parametrar/novatrix-test.env
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")" || exit 1

PARAMFIL="../parametrar/novatrix.env"
if [ "${1:-}" = "-p" ]; then PARAMFIL="$2"; shift 2; fi
# shellcheck source=../parametrar/novatrix.env
source "$PARAMFIL"
KEY_FIL="$(pwd)/${PREFIX}-key.pem"

ut() { aws cloudformation describe-stacks --stack-name "$PREFIX-$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text 2>/dev/null; }
WEB_IP=$(ut webb WebPublicIp)
[ -n "$WEB_IP" ] && [ "$WEB_IP" != "None" ] || { echo "Stacken $PREFIX-webb saknas. Kor deploy.sh forst."; exit 1; }
WEB_PRIV=$(ut webb WebPrivateIp);   BASTION_IP=$(ut webb BastionPublicIp)
DB_ID=$(ut data DbInstanceId);      DB_HOST=$(ut data DbEndpoint)
EFS_ID=$(ut data FileSystemId);     BUCKET=$(ut data BackupBucket)
WEB_SG=$(ut natverk WebSecurityGroupId); DB_SG=$(ut natverk DbSecurityGroupId)
EFS_SG=$(ut natverk EfsSecurityGroupId); BASTION_SG=$(ut natverk BastionSecurityGroupId)
MGMT_NACL=$(ut natverk MgmtNaclId);  PRIV_RT=$(ut natverk PrivateRouteTableId)
DB_PORT=$(ut natverk DbPort);        MIN_IP=$(ut natverk MyIp)
CS_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')
WEB_AZ=$(aws ec2 describe-instances --instance-ids "$(ut webb InstanceId)" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
EFS_IP=$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query "MountTargets[?AvailabilityZoneName=='$WEB_AZ'].IpAddress | [0]" --output text)

# ---------- hjalpfunktioner ----------
OK=0; FEL=0
resultat() {  # beskrivning forvantat faktiskt
  local s="OK"
  if [ "$2" = "$3" ]; then OK=$((OK+1)); else s="FEL"; FEL=$((FEL+1)); fi
  printf "  %-52s forvantat %-11s fick %-11s [%s]\n" "$1" "$2" "$3" "$s"
}
TCP_TEST='t(){ out=$(timeout 4 bash -c "</dev/tcp/$1/$2" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo TILLATET; elif [ $rc -eq 124 ]; then echo BLOCKERAT
  elif [[ $out == *refused* ]]; then echo STANGD; else echo BLOCKERAT; fi; }; t'
tcp() { bash -c "$TCP_TEST \"\$@\"" _ "$1" "$2"; }
jn() { [ "$1" = "$2" ] && echo JA || echo NEJ; }
kallor() {  # security group -> vilka kallor som slapps in
  aws ec2 describe-security-groups --group-ids "$1" \
    --query "SecurityGroups[0].IpPermissions[].[join(',',IpRanges[].CidrIp), join(',',UserIdGroupPairs[].GroupId)]" \
    --output text | tr -s '\t\n' ' ' | xargs
}
drift() {  # stack -> IN_SYNC eller DRIFTED
  local id s=""
  id=$(aws cloudformation detect-stack-drift --stack-name "$1" --query StackDriftDetectionId --output text)
  for _ in $(seq 1 40); do
    s=$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$id" \
      --query DetectionStatus --output text)
    [ "$s" != DETECTION_IN_PROGRESS ] && break; sleep 3
  done
  aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$id" \
    --query StackDriftStatus --output text
}

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

echo "Novatrix v46 - verifiering av miljon $PREFIX, $(date '+%Y-%m-%d %H:%M')"
echo "Webb $WEB_IP ($WEB_PRIV, $WEB_AZ) | Bastion $BASTION_IP | CloudShell $CS_IP"

# ---------- 1. Stackarna ----------
echo ""
echo "==> 1/5 Stackarna i CloudFormation"
for lager in natverk data webb; do
  STATUS=$(aws cloudformation describe-stacks --stack-name "$PREFIX-$lager" --query 'Stacks[0].StackStatus' --output text)
  resultat "Stack $PREFIX-$lager, status klar (*_COMPLETE)" JA "$([[ "$STATUS" =~ ^(CREATE|UPDATE)_COMPLETE$ ]] && echo JA || echo "$STATUS")"
done
echo "    Driftkontroll: jamfor verkligheten med mallarna (tar en minut)..."
for lager in natverk data webb; do
  D=$(drift "$PREFIX-$lager")
  resultat "Drift i $PREFIX-$lager (andrat utanfor koden)" IN_SYNC "$D"
  if [ "$D" = DRIFTED ]; then
    aws cloudformation describe-stack-resource-drifts --stack-name "$PREFIX-$lager" \
      --stack-resource-drift-status-filters MODIFIED DELETED \
      --query 'StackResourceDrifts[].[LogicalResourceId,StackResourceDriftStatus,PropertyDifferences[0].PropertyPath]' \
      --output text | sed 's/^/      /'
  fi
done
resultat "Natverkets db-sg anvands av"   "$PREFIX-data" "$(aws cloudformation list-imports \
  --export-name "$PREFIX-db-sg-id" --query 'Imports' --output text 2>/dev/null)"
resultat "Datalagrets efs-id anvands av" "$PREFIX-webb" "$(aws cloudformation list-imports \
  --export-name "$PREFIX-efs-id" --query 'Imports' --output text 2>/dev/null)"

# ---------- 2. WordPress ----------
echo ""
echo "==> 2/5 WordPress fran internet"
SIDA=$(curl -skL --max-time 10 "http://$WEB_IP/")
resultat "HTTP 80, WordPress svarar med 200"             200 "$(curl -skL -o /dev/null -w '%{http_code}' --max-time 10 "http://$WEB_IP/")"
resultat "Sidan ar WordPress (wp-content/wp-includes)"   JA  "$(grep -qE 'wp-(content|includes|admin)' <<<"$SIDA" && echo JA || echo NEJ)"
resultat "Inget databasfel (Error establishing...)"      JA  "$(grep -q 'Error establishing a database connection' <<<"$SIDA" && echo NEJ || echo JA)"
resultat "HTTPS 443 (sjalvsignerat)"                     200 "$(curl -skL -o /dev/null -w '%{http_code}' --max-time 10 "https://$WEB_IP/")"
resultat "SSH 22 direkt till webbservern"                BLOCKERAT "$(tcp "$WEB_IP" 22)"
grep -q 'install.php' <<<"$SIDA" && echo "    OBS: WordPress ar inte installerad an. Oppna http://$WEB_IP och kor installationen."

# ---------- 3. Databasen ----------
echo ""
echo "==> 3/5 Databasen (RDS $DB_ID)"
rds() { aws rds describe-db-instances --db-instance-identifier "$DB_ID" --query "DBInstances[0].$1" --output text; }
resultat "Publikt atkomlig (PubliclyAccessible)"         False "$(rds PubliclyAccessible)"
resultat "Krypterad i vila (StorageEncrypted)"           True  "$(rds StorageEncrypted)"
resultat "Automatisk backup, dagar"                      "$RDS_BACKUP_DAGAR" "$(rds BackupRetentionPeriod)"
DB_IP=$(python3 -c "import socket,sys; print(socket.gethostbyname(sys.argv[1]))" "$DB_HOST" 2>/dev/null)
resultat "DNS-namnet pekar pa en privat IP ($DB_IP)"     JA  "$([[ "$DB_IP" =~ ^10\. ]] && echo JA || echo NEJ)"
resultat "MariaDB $DB_PORT fran internet (CloudShell)"   BLOCKERAT "$(tcp "$DB_HOST" "$DB_PORT")"
resultat "db-sg slapper bara in webb-sg"                 JA  "$(jn "$(kallor "$DB_SG")" "$WEB_SG")"
VAGAR=$(aws ec2 describe-route-tables --route-table-ids "$PRIV_RT" \
  --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)
resultat "Privata subnat har vag till internet"          NEJ "$([ "$VAGAR" = 0 ] && echo NEJ || echo JA)"

# ---------- 4. EFS och S3 ----------
echo ""
echo "==> 4/5 Lagring: EFS $EFS_ID och s3://$PREFIX-backup-<konto-id>"
resultat "EFS krypterad i vila"                          True "$(aws efs describe-file-systems --file-system-id "$EFS_ID" \
  --query 'FileSystems[0].Encrypted' --output text)"
resultat "EFS mount targets som ar 'available'"          2 "$(aws efs describe-mount-targets --file-system-id "$EFS_ID" \
  --query "length(MountTargets[?LifeCycleState=='available'])" --output text)"
resultat "efs-sg slapper bara in webb-sg"                JA "$(jn "$(kallor "$EFS_SG")" "$WEB_SG")"
resultat "S3: all publik atkomst blockerad"              JA "$(jn "$(aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
  --output text | xargs)" "True True True True")"
resultat "S3: livscykelregel, backup/ raderas efter dagar" "$S3_BACKUP_DAGAR" "$(aws s3api get-bucket-lifecycle-configuration \
  --bucket "$BUCKET" --query "Rules[?Status=='Enabled'] | [0].Expiration.Days" --output text)"
resultat "S3: atkomst over HTTP utan TLS (som admin)"    NEKAD "$(aws s3api list-objects-v2 --bucket "$BUCKET" \
  --endpoint-url http://s3.eu-north-1.amazonaws.com --max-items 1 >/dev/null 2>&1 && echo TILLATEN || echo NEKAD)"

# ---------- 5. Inifran ----------
echo ""
echo "==> 5/5 Inifran, via bastion"
if [ "$CS_IP/32" != "$MIN_IP" ]; then
  # Andras utanfor koden bara under testet. Driftkontrollen i del 1 ar redan gjord.
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
  resultat "Webb: EFS monterad pa wp-content"            JA   "$(pa_webb 'mountpoint -q /var/www/html/wp-content && echo JA || echo NEJ')"
  resultat "Webb: filsystemstyp pa wp-content"           nfs4 "$(pa_webb 'findmnt -no FSTYPE /var/www/html/wp-content')"
  TABELLER=$(pa_webb "sudo /usr/local/bin/novatrix-mysql mysql -N -e 'SHOW TABLES' wordpress | wc -l")
  resultat "Webb: WordPress-tabeller i RDS ($TABELLER st)" JA  "$([ "${TABELLER:-0}" -gt 0 ] 2>/dev/null && echo JA || echo NEJ)"
  resultat "Webb -> databasen $DB_PORT"                  TILLATET  "$(pa_webb "$TCP_TEST $DB_HOST $DB_PORT")"
  resultat "Webb -> EFS 2049"                            TILLATET  "$(pa_webb "$TCP_TEST $EFS_IP 2049")"
  resultat "Bastion -> databasen $DB_PORT"               BLOCKERAT "$(pa_bastion "$TCP_TEST $DB_HOST $DB_PORT")"
  resultat "Bastion -> EFS 2049"                         BLOCKERAT "$(pa_bastion "$TCP_TEST $EFS_IP 2049")"
  resultat "Bastion -> internet HTTPS 443"               BLOCKERAT "$(pa_bastion "$TCP_TEST s3.eu-north-1.amazonaws.com 443")"
  resultat "Webb: backup-timer aktiv (varje natt 02:00)" enabled   "$(pa_webb 'systemctl is-enabled novatrix-backup.timer')"
  echo "    Kor en backup nu i stallet for att vanta till natten..."
  pa_webb 'sudo systemctl start novatrix-backup.service && sudo journalctl -u novatrix-backup -o cat | grep "Backup klar" | tail -1' | sed 's/^/    /'
  SENASTE=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix backup/ \
    --query 'sort_by(Contents,&LastModified)[-1].Key' --output text 2>/dev/null)
  resultat "Backup finns i S3 ($SENASTE)"                JA "$([[ "$SENASTE" == backup/wordpress-*.sql.gz ]] && echo JA || echo NEJ)"
else
  echo "  Hoppar over: nyckeln $(basename "$KEY_FIL") saknas i den har mappen."
fi

echo ""
echo "==> Sammanfattning: ${OK} OK, ${FEL} FEL"
