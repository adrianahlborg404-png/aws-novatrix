#!/bin/bash
# =============================================================
# iam-setup.sh - Novatrix AB, AWS v43
# Skapar S3-bucket, IAM-policies, grupper, anvandare och roller
# enligt least privilege. Tal att koras flera ganger.
#
# Kors i AWS CloudShell (region Stockholm, eu-north-1):
#   cd aws-novatrix/v43/scripts
#   bash iam-setup.sh
# =============================================================
set -euo pipefail

REGION="eu-north-1"
export AWS_DEFAULT_REGION="$REGION"
cd "$(dirname "$0")"

KONTO=$(aws sts get-caller-identity --query Account --output text)
BUCKET="novatrix-webb-${KONTO}"
TAGG="Key=Projekt,Value=novatrix"

# Fyll i konto-ID och bucketnamn i policy-mallarna (__KONTO__, __BUCKET__)
POL=$(mktemp -d)
for f in ../policies/*.json; do
  sed -e "s/__KONTO__/${KONTO}/g" -e "s/__BUCKET__/${BUCKET}/g" "$f" > "$POL/$(basename "$f")"
done

# ---------- hjalpfunktioner (gor inget om resursen redan finns) ----------
skapa_policy() {   # namn fil
  local arn="arn:aws:iam::${KONTO}:policy/$1"
  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    echo "    policy $1 finns redan"
  else
    aws iam create-policy --policy-name "$1" --policy-document "file://$POL/$2" \
      --tags "$TAGG" >/dev/null
    echo "    policy $1 skapad"
  fi
}

skapa_grupp() {    # grupp policy
  aws iam get-group --group-name "$1" >/dev/null 2>&1 || aws iam create-group --group-name "$1" >/dev/null
  aws iam attach-group-policy --group-name "$1" --policy-arn "arn:aws:iam::${KONTO}:policy/$2"
  echo "    grupp $1 <- $2"
}

skapa_anvandare() { # anvandare grupp team
  aws iam get-user --user-name "$1" >/dev/null 2>&1 || \
    aws iam create-user --user-name "$1" --tags "$TAGG" "Key=team,Value=$3" >/dev/null
  aws iam add-user-to-group --user-name "$1" --group-name "$2"
  echo "    anvandare $1 (team=$3) i $2"
}

skapa_roll() {     # roll trust-fil policy
  aws iam get-role --role-name "$1" >/dev/null 2>&1 || \
    aws iam create-role --role-name "$1" --assume-role-policy-document "file://$POL/$2" \
      --max-session-duration 3600 --tags "$TAGG" >/dev/null
  aws iam attach-role-policy --role-name "$1" --policy-arn "arn:aws:iam::${KONTO}:policy/$3"
  echo "    roll $1 <- $3"
}

# ---------- 1. S3-bucket for webbfiler ----------
echo "==> 1/5 S3-bucket $BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "    finns redan"
else
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=Projekt,Value=novatrix}]'
  echo "    skapad (privat, all publik atkomst blockerad)"
fi
aws s3 cp ../../v42/webb/index.html "s3://${BUCKET}/webb/index.html" >/dev/null
echo "    webb/index.html uppladdad fran v42"

# ---------- 2. Kundhanterade policies ----------
echo "==> 2/5 Policies"
skapa_policy novatrix-drift-policy      drift.json
skapa_policy novatrix-utveckling-policy utveckling.json
skapa_policy novatrix-web-s3-read       web-s3-read.json
skapa_policy novatrix-deploy-s3-write   deploy-s3-write.json

# ---------- 3. Grupper ----------
echo "==> 3/5 Grupper"
skapa_grupp novatrix-drift      novatrix-drift-policy
skapa_grupp novatrix-utveckling novatrix-utveckling-policy

# ---------- 4. Anvandare (utan losenord och utan nycklar) ----------
echo "==> 4/5 Anvandare"
skapa_anvandare anna-drift novatrix-drift      drift
skapa_anvandare erik-utv   novatrix-utveckling utveckling

# ---------- 5. Roller ----------
echo "==> 5/5 Roller"
skapa_roll novatrix-web-role    trust-ec2.json    novatrix-web-s3-read
skapa_roll novatrix-deploy-role trust-deploy.json novatrix-deploy-s3-write

# EC2 anvander en roll via en instance profile
if ! aws iam get-instance-profile --instance-profile-name novatrix-web-role >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name novatrix-web-role >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name novatrix-web-role \
    --role-name novatrix-web-role
fi
echo "    instance profile novatrix-web-role"

rm -rf "$POL"
echo ""
echo "    Klart. Nasta steg: bash deploy.sh [DIN-PUBLIKA-IP]"
