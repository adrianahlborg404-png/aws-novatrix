#!/bin/bash
# =============================================================
# teardown.sh - Novatrix AB, AWS v45
# Tar bort allt i omvand ordning mot deploy.sh:
#   instanser -> key pair -> datastacken (RDS, EFS, S3) ->
#   natverksstacken (v44) -> IAM och S3 fran v43
#
#   bash teardown.sh                # allt
#   bash teardown.sh --behall-iam   # behall IAM fran v43 till nasta pass
#
# RDS tar 5-10 minuter att ta bort.
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")" || exit 1
NAT_STACK="novatrix-natverk-v44"
DATA_STACK="novatrix-data-v45"

echo "==> 1/5 EC2-instanser"
INSTANSER=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=novatrix-web-v45,novatrix-bastion-v45 \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$INSTANSER" ]; then
  read -r -a IDS <<<"$INSTANSER"
  aws ec2 terminate-instances --instance-ids "${IDS[@]}" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "${IDS[@]}"
  echo "    terminerade: $INSTANSER"
fi

echo "==> 2/5 Key pair"
aws ec2 delete-key-pair --key-name novatrix-v45-key 2>/dev/null || true
rm -f novatrix-v45-key.pem

echo "==> 3/5 Datastacken $DATA_STACK (RDS, EFS, S3-backup)"
BUCKET=$(aws cloudformation describe-stacks --stack-name "$DATA_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='BackupBucket'].OutputValue" --output text 2>/dev/null || true)
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  # CloudFormation kan inte ta bort en bucket som innehaller filer
  aws s3 rm "s3://${BUCKET}" --recursive --only-show-errors
  echo "    backup-bucketen tommd"
fi
aws cloudformation delete-stack --stack-name "$DATA_STACK"
echo "    vantar, RDS tar 5-10 minuter..."
aws cloudformation wait stack-delete-complete --stack-name "$DATA_STACK" && echo "    borttagen"

echo "==> 4/5 Natverksstacken $NAT_STACK (fran v44)"
aws cloudformation delete-stack --stack-name "$NAT_STACK"
aws cloudformation wait stack-delete-complete --stack-name "$NAT_STACK" && echo "    borttagen"

echo "==> 5/5 IAM och S3 fran v43"
if [ "${1:-}" = "--behall-iam" ]; then
  echo "    behalls (--behall-iam)"
else
  bash ../../v43/scripts/teardown.sh
fi
