#!/bin/bash
# =============================================================
# teardown.sh - Novatrix AB, AWS v43
# Tar bort allt som iam-setup.sh och deploy.sh skapade.
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
KONTO=$(aws sts get-caller-identity --query Account --output text)
BUCKET="novatrix-webb-${KONTO}"
P="arn:aws:iam::${KONTO}:policy"

echo "==> 1/6 EC2-instans"
INSTANSER=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=novatrix-web-v43 \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$INSTANSER" ]; then
  aws ec2 terminate-instances --instance-ids $INSTANSER >/dev/null
  aws ec2 wait instance-terminated --instance-ids $INSTANSER
  echo "    terminerad: $INSTANSER"
fi

echo "==> 2/6 Security group och key pair"
aws ec2 delete-security-group --group-name novatrix-web-sg 2>/dev/null || true
aws ec2 delete-key-pair --key-name novatrix-key 2>/dev/null || true
rm -f "$(dirname "$0")/novatrix-key.pem"

echo "==> 3/6 Roller och instance profile"
aws iam remove-role-from-instance-profile --instance-profile-name novatrix-web-role \
  --role-name novatrix-web-role 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name novatrix-web-role 2>/dev/null || true
aws iam detach-role-policy --role-name novatrix-web-role    --policy-arn "$P/novatrix-web-s3-read"     2>/dev/null || true
aws iam detach-role-policy --role-name novatrix-deploy-role --policy-arn "$P/novatrix-deploy-s3-write" 2>/dev/null || true
aws iam delete-role --role-name novatrix-web-role    2>/dev/null || true
aws iam delete-role --role-name novatrix-deploy-role 2>/dev/null || true

echo "==> 4/6 Anvandare"
for u in anna-drift:novatrix-drift erik-utv:novatrix-utveckling; do
  user="${u%%:*}"; grupp="${u##*:}"
  for k in $(aws iam list-access-keys --user-name "$user" \
              --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
    aws iam delete-access-key --user-name "$user" --access-key-id "$k"
  done
  aws iam remove-user-from-group --user-name "$user" --group-name "$grupp" 2>/dev/null || true
  aws iam delete-user --user-name "$user" 2>/dev/null || true
done

echo "==> 5/6 Grupper och policies"
aws iam detach-group-policy --group-name novatrix-drift      --policy-arn "$P/novatrix-drift-policy"      2>/dev/null || true
aws iam detach-group-policy --group-name novatrix-utveckling --policy-arn "$P/novatrix-utveckling-policy" 2>/dev/null || true
aws iam delete-group --group-name novatrix-drift      2>/dev/null || true
aws iam delete-group --group-name novatrix-utveckling 2>/dev/null || true
for pol in novatrix-drift-policy novatrix-utveckling-policy novatrix-web-s3-read novatrix-deploy-s3-write; do
  aws iam delete-policy --policy-arn "$P/$pol" 2>/dev/null || true
done

echo "==> 6/6 S3-bucket"
aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true

echo "==> Klart, miljon ar borttagen"
