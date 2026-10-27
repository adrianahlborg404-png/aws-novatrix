#!/bin/bash
# =============================================================
# visa-iam.sh - Novatrix AB, AWS v43
# Hamtar fran AWS och skriver ut vad som ar uppsatt: grupper,
# anvandare, roller, policies (fullt innehall), EC2-instansens
# roll och S3-bucketens installningar. Andrar ingenting.
# Konto-ID maskeras sa att utskriften kan delas.
#
#   bash visa-iam.sh                      # visa i terminalen
#   bash visa-iam.sh | tee iam-oversikt.txt   # spara aven till fil
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"

KONTO=$(aws sts get-caller-identity --query Account --output text)
BUCKET="novatrix-webb-${KONTO}"
P="arn:aws:iam::${KONTO}:policy"

maska()  { sed "s/${KONTO}/<konto-id>/g"; }
indrag() { sed "s/^/$1/"; }
rubrik() { echo ""; echo "=================================================================="; echo " $1"; echo "=================================================================="; }

visa_policy() {   # policynamn
  local ver
  ver=$(aws iam get-policy --policy-arn "$P/$1" --query 'Policy.DefaultVersionId' --output text)
  echo "    Policy: $1"
  aws iam get-policy-version --policy-arn "$P/$1" --version-id "$ver" \
    --query 'PolicyVersion.Document' --output json | jq . | maska | indrag "      "
}

visa_bifogade() { # group|role namn
  local pols
  pols=$(aws iam "list-attached-$1-policies" "--$1-name" "$2" \
    --query 'AttachedPolicies[].PolicyName' --output text)
  for pol in $pols; do visa_policy "$pol"; done
}

echo "Novatrix AB - IAM-oversikt v43, $(date '+%Y-%m-%d %H:%M')"
echo "Konto: <konto-id>   Region: eu-north-1"

# ---------- Grupper ----------
for g in novatrix-drift novatrix-utveckling; do
  rubrik "GRUPP: $g"
  echo "  Medlemmar: $(aws iam get-group --group-name "$g" --query 'Users[].UserName' --output text)"
  echo "  Behorigheter:"
  visa_bifogade group "$g"
done

# ---------- Anvandare ----------
rubrik "ANVANDARE"
printf "  %-12s %-22s %-12s %-10s %s\n" "Namn" "Grupp" "Tagg team" "Losenord" "Access keys"
for u in anna-drift erik-utv; do
  grupp=$(aws iam list-groups-for-user --user-name "$u" --query 'Groups[].GroupName' --output text)
  team=$(aws iam list-user-tags --user-name "$u" --query "Tags[?Key=='team'].Value" --output text)
  if aws iam get-login-profile --user-name "$u" >/dev/null 2>&1; then los="ja"; else los="nej"; fi
  nycklar=$(aws iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)' --output text)
  printf "  %-12s %-22s %-12s %-10s %s\n" "$u" "$grupp" "$team" "$los" "$nycklar"
done
echo "  Inga egna policies pa anvandarna, all behorighet kommer fran gruppen."

# ---------- Roller ----------
for r in novatrix-deploy-role novatrix-web-role; do
  rubrik "ROLL: $r"
  echo "  Max sessionstid: $(aws iam get-role --role-name "$r" --query 'Role.MaxSessionDuration' --output text) sekunder"
  echo "  Trust policy (VEM far anta rollen):"
  aws iam get-role --role-name "$r" --query 'Role.AssumeRolePolicyDocument' --output json \
    | jq . | maska | indrag "      "
  echo "  Behorigheter (VAD rollen far gora):"
  visa_bifogade role "$r"
done

# ---------- EC2 ----------
rubrik "EC2-INSTANS: novatrix-web-v43"
aws ec2 describe-instances \
  --filters Name=tag:Name,Values=novatrix-web-v43 Name=instance-state-name,Values=pending,running,stopped \
  --query 'Reservations[].Instances[].{Instans:InstanceId,Status:State.Name,Roll:IamInstanceProfile.Arn,IMDSv2:MetadataOptions.HttpTokens,PublikIP:PublicIpAddress,Projekttagg:Tags[?Key==`Projekt`]|[0].Value}' \
  --output table | maska | indrag "  "

# ---------- S3 ----------
rubrik "S3-BUCKET: novatrix-webb-<konto-id>"
echo "  Blockering av publik atkomst:"
aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration' --output table | indrag "  "
echo "  Innehall:"
aws s3 ls "s3://${BUCKET}" --recursive | indrag "    "
echo ""
