#!/bin/bash
# =============================================================
# deploy.sh - Novatrix AB, AWS v43
# Samma webbserver som v42, men instansen far IAM-rollen
# novatrix-web-role och hamtar webbsidan fran S3.
# Kor iam-setup.sh forst.
#
#   bash deploy.sh [DIN-PUBLIKA-IP]   (IP behovs bara for SSH)
# =============================================================
set -euo pipefail

REGION="eu-north-1"
NAMN="novatrix-web-v43"
INSTANSTYP="t3.micro"
KEY_NAME="novatrix-key"
SG_NAME="novatrix-web-sg"
PROFIL="novatrix-web-role"
MITT_IP="${1:-}"

export AWS_DEFAULT_REGION="$REGION"
cd "$(dirname "$0")"

KONTO=$(aws sts get-caller-identity --query Account --output text)
BUCKET="novatrix-webb-${KONTO}"

echo "==> 1/6 Kontrollerar att iam-setup.sh har korts"
aws iam get-instance-profile --instance-profile-name "$PROFIL" >/dev/null 2>&1 || {
  echo "    Instance profile $PROFIL saknas. Kor: bash iam-setup.sh"; exit 1; }

echo "==> 2/6 Hamtar senaste Amazon Linux 2023-AMI"
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
echo "    AMI: $AMI_ID"

echo "==> 3/6 Key pair"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "    $KEY_NAME finns redan, ateranvands"
else
  aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
    --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  echo "    Sparad som ${KEY_NAME}.pem (lagg den INTE i GitHub)"
fi

echo "==> 4/6 Security group i default-VPC"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" \
    --description "Novatrix webb: HTTP fran alla, SSH fran min IP" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
  if [ -n "$MITT_IP" ]; then
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port 22 --cidr "${MITT_IP}/32" >/dev/null
    echo "    SSH oppnad for ${MITT_IP}/32"
  fi
fi
echo "    SG: $SG_ID"

echo "==> 5/6 Startar EC2-instans med rollen $PROFIL"
UD=$(mktemp)
sed "s/__BUCKET__/${BUCKET}/g" user-data.sh > "$UD"
# En ny instance profile kan ta nagra sekunder innan EC2 ser den, darfor nya forsok
for i in 1 2 3 4 5 6; do
  INSTANS_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANSTYP" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --iam-instance-profile Name="$PROFIL" \
    --metadata-options HttpTokens=required \
    --user-data "file://$UD" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAMN},{Key=Projekt,Value=novatrix}]" \
    --query 'Instances[0].InstanceId' --output text 2>/dev/null) && break
  echo "    instance profile inte redo an, forsoker igen om 10 s..."
  sleep 10
done
rm -f "$UD"
[ -n "${INSTANS_ID:-}" ] || { echo "    Kunde inte starta instansen"; exit 1; }
echo "    Instans: $INSTANS_ID - vantar pa 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANS_ID"

echo "==> 6/6 Klart"
PUBLIK_IP=$(aws ec2 describe-instances --instance-ids "$INSTANS_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo ""
echo "    Webbsida: http://$PUBLIK_IP           (ge user data 2 minuter)"
echo "    IAM-test: http://$PUBLIK_IP/iam-test.txt"
echo "    Verifiera alla roller: bash verify.sh"
echo "    Riv ner:  bash teardown.sh"
