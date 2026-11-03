#!/bin/bash
# =============================================================
# deploy.sh - Novatrix AB, AWS v44
# 1. Skapar natverket fran CloudFormation-mallen natverk.yaml
#    (VPC, subnat, routing, NACL:er, security groups, flow logs)
# 2. Startar webbservern i det publika webbsubnatet (med IAM-rollen
#    fran v43) och en bastion i mgmt-subnatet.
# Kor v43/scripts/iam-setup.sh forst (S3-bucket och webb-rollen).
#
#   bash deploy.sh <DIN-PUBLIKA-IP>
#   Din dators publika IP blir admin-IP, den enda som far SSH:a
#   till bastion. Utelamnad ateranvands IP:n som redan finns i
#   stacken, och forsta gangen CloudShells egen IP.
# =============================================================
set -euo pipefail

REGION="eu-north-1"
STACK="novatrix-natverk-v44"
INSTANSTYP="t3.micro"
KEY_NAME="novatrix-v44-key"
PROFIL="novatrix-web-role"
WEBB_NAMN="novatrix-web-v44"
BASTION_NAMN="novatrix-bastion-v44"

export AWS_DEFAULT_REGION="$REGION"
cd "$(dirname "$0")"
KEY_FIL="$(pwd)/${KEY_NAME}.pem"

KONTO=$(aws sts get-caller-identity --query Account --output text)
BUCKET="novatrix-webb-${KONTO}"

echo "==> 1/7 Kontrollerar IAM och S3 fran v43"
aws iam get-instance-profile --instance-profile-name "$PROFIL" >/dev/null 2>&1 && \
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || {
  echo "    Rollen $PROFIL eller bucketen saknas. Kor forst:"
  echo "    cd ../../v43/scripts && bash iam-setup.sh && cd ../../v44/scripts"
  exit 1; }
echo "    OK: $PROFIL och s3://novatrix-webb-<konto-id>"

echo "==> 2/7 Admin-IP"
NUVARANDE=$(aws cloudformation describe-stacks --stack-name "$STACK" \
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

echo "==> 3/7 Natverk fran kod: CloudFormation-stack $STACK"
echo "    (forsta gangen tar det 2-3 minuter)"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file ../cloudformation/natverk.yaml \
  --parameter-overrides "AdminIp=$ADMIN_IP" \
  --capabilities CAPABILITY_IAM \
  --tags Projekt=novatrix \
  --no-fail-on-empty-changeset

ut() { aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
WEB_SUBNET=$(ut WebSubnetId);  MGMT_SUBNET=$(ut MgmtSubnetId)
WEB_SG=$(ut WebSgId);          BASTION_SG=$(ut BastionSgId)
echo "    VPC $(ut VpcId) | webb-subnat $WEB_SUBNET | mgmt-subnat $MGMT_SUBNET"

echo "==> 4/7 Senaste Amazon Linux 2023-AMI"
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
echo "    AMI: $AMI_ID"

echo "==> 5/7 Key pair $KEY_NAME"
if [ -f "$KEY_FIL" ] && aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "    finns redan, ateranvands"
else
  # Nyckeln i AWS ar oanvandbar utan .pem-filen, sa skapa om bada
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

echo "==> 6/7 Webbserver $WEBB_NAMN i publikt webbsubnat"
WEB_ID=$(instans_id "$WEBB_NAMN")
if [ "$WEB_ID" != "None" ]; then
  echo "    finns redan: $WEB_ID"
else
  UD=$(mktemp)
  sed "s/__BUCKET__/${BUCKET}/g" user-data.sh > "$UD"
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

echo "==> 7/7 Bastion $BASTION_NAMN i publikt mgmt-subnat"
# Ingen IAM-roll och ingen user data: bastion behover inga AWS-rattigheter,
# den ar bara en hoppunkt for SSH.
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
echo "    Webbsida:  http://$WEB_IP  och  https://$WEB_IP  (ge user data 2 minuter)"
echo "    Natinfo:   http://$WEB_IP/natverk.txt"
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
echo "    Sedan i PowerShell: ssh novatrix-web"
echo ""
echo "    Verifiera trafiken: bash verify.sh"
echo "    Visa flow logs:     bash visa-trafik.sh"
echo "    Riv ner:            bash teardown.sh"
