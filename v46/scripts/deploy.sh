#!/bin/bash
# =============================================================
# deploy.sh - Novatrix AB, AWS v46
# Bygger HELA miljon fran repot med CloudFormation, utan klick i
# konsolen. Tre stackar i ordning, varje stack laser det den
# behover fran den forra med !ImportValue:
#   1. <prefix>-natverk  VPC, subnat, NACL, security groups, flow logs
#   2. <prefix>-data     RDS, Secrets Manager, EFS, S3-backup
#   3. <prefix>-webb     roll, key pair, WordPress-server, bastion
#
#   bash deploy.sh <DIN-PUBLIKA-IP>
#   bash deploy.sh -p ../parametrar/novatrix-test.env <DIN-PUBLIKA-IP>
#   FELSOK=1 bash deploy.sh <IP>     # ingen rollback vid fel, for felsokning
#
# Samma kommando uppdaterar en befintlig miljo: CloudFormation
# raknar ut skillnaden och andrar bara det som behovs.
# Forsta gangen tar det 15-25 minuter (RDS och WordPress-servern).
# =============================================================
set -euo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")"

PARAMFIL="../parametrar/novatrix.env"
if [ "${1:-}" = "-p" ]; then PARAMFIL="$2"; shift 2; fi
# shellcheck source=../parametrar/novatrix.env
source "$PARAMFIL"
MALLAR="../cloudformation"
TAGGAR=(Projekt=novatrix "Miljo=$PREFIX")
ROLLBACK=()
[ "${FELSOK:-0}" = 1 ] && ROLLBACK=(--disable-rollback)
echo "Miljo: $PREFIX (parametrar fran $PARAMFIL)"

echo "==> 1/6 Validerar mallarna"
for lager in natverk data webb; do
  aws cloudformation validate-template --template-body "file://$MALLAR/$lager.yaml" >/dev/null
  echo "    $lager.yaml OK"
done

echo "==> 2/6 Min IP (den enda som far SSH:a till bastion)"
NUVARANDE=$(aws cloudformation describe-stacks --stack-name "$PREFIX-natverk" \
  --query "Stacks[0].Parameters[?ParameterKey=='MyIp'].ParameterValue" --output text 2>/dev/null || true)
if [ -n "${1:-}" ]; then
  MIN_IP="$1";                KALLA="angiven"
elif [[ "$NUVARANDE" =~ ^[0-9.]+/32$ ]]; then
  MIN_IP="${NUVARANDE%/32}";  KALLA="samma som forut i stacken"
else
  MIN_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]'); KALLA="CloudShells IP, ingen IP angavs"
fi
[[ "$MIN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "    Ogiltig IP: $MIN_IP"; exit 1; }
echo "    $MIN_IP/32 ($KALLA)"

echo "==> 3/6 Natverksstacken $PREFIX-natverk"
aws cloudformation deploy "${ROLLBACK[@]}" \
  --stack-name "$PREFIX-natverk" \
  --template-file "$MALLAR/natverk.yaml" \
  --parameter-overrides "Prefix=$PREFIX" "MyIp=$MIN_IP/32" "VpcCidr=$VPC_CIDR" \
  --capabilities CAPABILITY_IAM \
  --tags "${TAGGAR[@]}" \
  --no-fail-on-empty-changeset

echo "==> 4/6 Datastacken $PREFIX-data (forsta gangen 10-15 min, RDS tar langst tid)"
aws cloudformation deploy "${ROLLBACK[@]}" \
  --stack-name "$PREFIX-data" \
  --template-file "$MALLAR/data.yaml" \
  --parameter-overrides "Prefix=$PREFIX" "DbInstanceClass=$DB_KLASS" "DbStorageGb=$DB_LAGRING_GB" \
    "RdsBackupDays=$RDS_BACKUP_DAGAR" "S3BackupDays=$S3_BACKUP_DAGAR" \
  --tags "${TAGGAR[@]}" \
  --no-fail-on-empty-changeset

echo "==> 5/6 Webbstacken $PREFIX-webb (vantar tills WordPress svarar, 5-10 min)"
aws cloudformation deploy "${ROLLBACK[@]}" \
  --stack-name "$PREFIX-webb" \
  --template-file "$MALLAR/webb.yaml" \
  --parameter-overrides "Prefix=$PREFIX" "InstanceType=$INSTANSTYP" \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags "${TAGGAR[@]}" \
  --no-fail-on-empty-changeset

ut() { aws cloudformation describe-stacks --stack-name "$PREFIX-webb" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

echo "==> 6/6 Privata nyckeln fran SSM Parameter Store"
# Key pair skapas av stacken. AWS sparar privata nyckeln krypterad i
# SSM under /ec2/keypair/<id>. Den hamtas hit och laggs aldrig i Git.
KEY_FIL="$(pwd)/${PREFIX}-key.pem"
rm -f "$KEY_FIL"
aws ssm get-parameter --name "/ec2/keypair/$(ut KeyPairId)" --with-decryption \
  --query Parameter.Value --output text > "$KEY_FIL"
chmod 400 "$KEY_FIL"
echo "    sparad som ${PREFIX}-key.pem (lagg den INTE i GitHub)"

WEB_IP=$(ut WebPublicIp); WEB_PRIV=$(ut WebPrivateIp); BASTION_IP=$(ut BastionPublicIp)
echo ""
echo "    Klart. Alla tre stackarna ar skapade fran repot."
echo "    WordPress: http://$WEB_IP"
echo "    Forsta gangen: valj sprak, sajtens namn och ett admin-konto."
echo "    Databasen ar redan inkopplad via wp-config.php."
echo "    Bastion:   $BASTION_IP (SSH bara fran $MIN_IP)"
echo ""
echo "    SSH fran din dator: ladda ner ${PREFIX}-key.pem (Actions -> Download file),"
echo "    lagg den i C:\\Users\\<du>\\.ssh\\ och lagg till i C:\\Users\\<du>\\.ssh\\config:"
echo ""
echo "      Host ${PREFIX}-bastion"
echo "        HostName $BASTION_IP"
echo "        User ec2-user"
echo "        IdentityFile ~/.ssh/${PREFIX}-key.pem"
echo "      Host ${PREFIX}-web"
echo "        HostName $WEB_PRIV"
echo "        User ec2-user"
echo "        IdentityFile ~/.ssh/${PREFIX}-key.pem"
echo "        ProxyJump ${PREFIX}-bastion"
echo ""
echo "    Verifiera: bash verify.sh"
echo "    Andring:   bash andring.sh <natverk|data|webb>"
echo "    Riv ner:   bash teardown.sh"
