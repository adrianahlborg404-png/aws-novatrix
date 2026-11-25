#!/bin/bash
# =============================================================
# deploy.sh - Novatrix AB, AWS v45
# Bygger WordPress-stacken:
#   1. Natverket fran v44 (samma mall, ../../v44/cloudformation/natverk.yaml)
#   2. Datalagret fran v45 (../cloudformation/data.yaml): RDS, EFS och S3-backup
#   3. Webbserver med WordPress i det publika subnatet, och bastion
# Kor v43/scripts/iam-setup.sh forst (webbserverns roll).
#
#   bash deploy.sh <DIN-PUBLIKA-IP>
#   Din dators publika IP blir admin-IP, den enda som far SSH:a till
#   bastion. Utelamnad ateranvands IP:n som redan finns i stacken.
#
# Forsta gangen tar det 10-15 minuter, mest for RDS.
# =============================================================
set -euo pipefail

REGION="eu-north-1"
NAT_STACK="novatrix-natverk-v44"
DATA_STACK="novatrix-data-v45"
INSTANSTYP="t3.micro"
KEY_NAME="novatrix-v45-key"
PROFIL="novatrix-web-role"
WEBB_NAMN="novatrix-web-v45"
BASTION_NAMN="novatrix-bastion-v45"

export AWS_DEFAULT_REGION="$REGION"
cd "$(dirname "$0")"
KEY_FIL="$(pwd)/${KEY_NAME}.pem"

echo "==> 1/8 Kontrollerar IAM fran v43"
aws iam get-instance-profile --instance-profile-name "$PROFIL" >/dev/null 2>&1 || {
  echo "    Rollen $PROFIL saknas. Kor forst:"
  echo "    cd ../../v43/scripts && bash iam-setup.sh && cd ../../v45/scripts"
  exit 1; }
echo "    OK: $PROFIL"

echo "==> 2/8 Admin-IP"
NUVARANDE=$(aws cloudformation describe-stacks --stack-name "$NAT_STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='AdminIp'].ParameterValue" --output text 2>/dev/null || true)
if [ -n "${1:-}" ]; then
  ADMIN_IP="$1";         KALLA="angiven"
elif [[ "$NUVARANDE" =~ ^[0-9.]+$ ]]; then
  ADMIN_IP="$NUVARANDE"; KALLA="samma som forut i stacken"
else
  ADMIN_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]'); KALLA="CloudShells IP, ingen IP angavs"
fi
[[ "$ADMIN_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "    Ogiltig IP: $ADMIN_IP"; exit 1; }
echo "    $ADMIN_IP ($KALLA)"

echo "==> 3/8 Natverket fran v44: stack $NAT_STACK"
aws cloudformation deploy \
  --stack-name "$NAT_STACK" \
  --template-file ../../v44/cloudformation/natverk.yaml \
  --parameter-overrides "AdminIp=$ADMIN_IP" \
  --capabilities CAPABILITY_IAM \
  --tags Projekt=novatrix \
  --no-fail-on-empty-changeset

nat() { aws cloudformation describe-stacks --stack-name "$NAT_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
VPC_ID=$(nat VpcId);           WEB_SUBNET=$(nat WebSubnetId); MGMT_SUBNET=$(nat MgmtSubnetId)
WEB_SG=$(nat WebSgId);         BASTION_SG=$(nat BastionSgId); DB_SG=$(nat DbSgId)
DB_SUBNETS=$(nat DbSubnetIds); DB_SUBNET_GROUP=$(nat DbSubnetGroup); DB_PORT=$(nat DbPort)
WEB_CIDR=$(aws cloudformation describe-stacks --stack-name "$NAT_STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='WebCidr'].ParameterValue" --output text)
# NACL:en for de privata subnaten finns inte som output i v44, sok upp den via taggen
DB_NACL=$(aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_ID" Name=tag:Name,Values=novatrix-db-nacl \
  --query 'NetworkAcls[0].NetworkAclId' --output text)
echo "    VPC $VPC_ID | privata subnat $DB_SUBNETS"

echo "==> 4/8 Datalagret fran kod: stack $DATA_STACK (RDS, EFS, S3)"
echo "    (forsta gangen 10-15 minuter, RDS tar langst tid)"
aws cloudformation deploy \
  --stack-name "$DATA_STACK" \
  --template-file ../cloudformation/data.yaml \
  --parameter-overrides \
    "VpcId=$VPC_ID" "DbSubnetIds=$DB_SUBNETS" "DbSubnetGroup=$DB_SUBNET_GROUP" \
    "WebSgId=$WEB_SG" "DbSgId=$DB_SG" "DbNaclId=$DB_NACL" \
    "WebCidr=$WEB_CIDR" "DbPort=$DB_PORT" "WebRoleName=$PROFIL" \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags Projekt=novatrix \
  --no-fail-on-empty-changeset

data() { aws cloudformation describe-stacks --stack-name "$DATA_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
DB_HOST=$(data DbEndpoint); SECRET_ARN=$(data DbSecretArn)
EFS_ID=$(data FileSystemId); BACKUP_BUCKET=$(data BackupBucket)
echo "    RDS $(data DbInstanceId) | EFS $EFS_ID | s3://novatrix-backup-<konto-id>"

echo "==> 5/8 Senaste Amazon Linux 2023-AMI"
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
echo "    AMI: $AMI_ID"

echo "==> 6/8 Key pair $KEY_NAME"
if [ -f "$KEY_FIL" ] && aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "    finns redan, ateranvands"
else
  aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 || true
  rm -f "$KEY_FIL"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
    --query 'KeyMaterial' --output text > "$KEY_FIL"
  chmod 400 "$KEY_FIL"
  echo "    sparad som ${KEY_NAME}.pem (lagg den INTE i GitHub)"
fi

instans_id() {  # namn -> id for instans som finns och inte ar pa vag bort
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

echo "==> 7/8 Webbserver $WEBB_NAMN med WordPress"
WEB_ID=$(instans_id "$WEBB_NAMN")
if [ "$WEB_ID" != "None" ]; then
  echo "    finns redan: $WEB_ID"
else
  UD=$(mktemp)
  sed -e "s|__EFS_ID__|${EFS_ID}|g" -e "s|__DB_HOST__|${DB_HOST}|g" \
      -e "s|__SECRET_ARN__|${SECRET_ARN}|g" -e "s|__BACKUP_BUCKET__|${BACKUP_BUCKET}|g" \
      user-data.sh > "$UD"
  WEB_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANSTYP" \
    --key-name "$KEY_NAME" \
    --subnet-id "$WEB_SUBNET" \
    --security-group-ids "$WEB_SG" \
    --associate-public-ip-address \
    --iam-instance-profile Name="$PROFIL" \
    --metadata-options HttpTokens=required \
    --user-data "file://$UD" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$WEBB_NAMN},{Key=Projekt,Value=novatrix},{Key=Roll,Value=webb}]" \
    --query 'Instances[0].InstanceId' --output text)
  rm -f "$UD"
  echo "    startad: $WEB_ID"
fi

echo "==> 8/8 Bastion $BASTION_NAMN"
BASTION_ID=$(instans_id "$BASTION_NAMN")
if [ "$BASTION_ID" != "None" ]; then
  echo "    finns redan: $BASTION_ID"
else
  BASTION_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANSTYP" \
    --key-name "$KEY_NAME" \
    --subnet-id "$MGMT_SUBNET" \
    --security-group-ids "$BASTION_SG" \
    --associate-public-ip-address \
    --metadata-options HttpTokens=required \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BASTION_NAMN},{Key=Projekt,Value=novatrix},{Key=Roll,Value=bastion}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "    startad: $BASTION_ID"
fi

echo "    Vantar pa 'running'..."
aws ec2 wait instance-running --instance-ids "$WEB_ID" "$BASTION_ID"

ip() { aws ec2 describe-instances --instance-ids "$1" \
  --query "Reservations[0].Instances[0].$2" --output text; }
WEB_IP=$(ip "$WEB_ID" PublicIpAddress); WEB_PRIV=$(ip "$WEB_ID" PrivateIpAddress)
BASTION_IP=$(ip "$BASTION_ID" PublicIpAddress)

echo ""
echo "    WordPress: http://$WEB_IP  (ge user data 3-4 minuter)"
echo "    Forsta gangen: valj sprak, sajtens namn och ett admin-konto."
echo "    Databasen ar redan inkopplad via wp-config.php, inget losenord behovs."
echo "    Bastion:   $BASTION_IP (SSH bara fran $ADMIN_IP)"
echo ""
echo "    SSH fran din dator: ladda ner ${KEY_NAME}.pem (Actions -> Download file),"
echo "    lagg den i C:\\Users\\<du>\\.ssh\\ och lagg till i C:\\Users\\<du>\\.ssh\\config:"
echo ""
echo "      Host novatrix-bastion"
echo "        HostName $BASTION_IP"
echo "        User ec2-user"
echo "        IdentityFile ~/.ssh/${KEY_NAME}.pem"
echo "      Host novatrix-web"
echo "        HostName $WEB_PRIV"
echo "        User ec2-user"
echo "        IdentityFile ~/.ssh/${KEY_NAME}.pem"
echo "        ProxyJump novatrix-bastion"
echo ""
echo "    Verifiera: bash verify.sh"
echo "    Riv ner:   bash teardown.sh"
