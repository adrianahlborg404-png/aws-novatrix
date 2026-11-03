#!/bin/bash
# =============================================================
# teardown.sh - Novatrix AB, AWS v44
# Tar bort allt som deploy.sh skapade: instanserna, key pair och
# hela natverksstacken. Kor sedan v43:s teardown.sh som tar bort
# IAM och S3-bucketen.
#
#   bash teardown.sh            # allt, aven IAM och S3 fran v43
#   bash teardown.sh --behall-iam   # behall IAM och S3 till nasta pass
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")"
STACK="novatrix-natverk-v44"

echo "==> 1/4 EC2-instanser"
INSTANSER=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=novatrix-web-v44,novatrix-bastion-v44 \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$INSTANSER" ]; then
  aws ec2 terminate-instances --instance-ids $INSTANSER >/dev/null
  aws ec2 wait instance-terminated --instance-ids $INSTANSER
  echo "    terminerade: $INSTANSER"
fi

echo "==> 2/4 Key pair"
aws ec2 delete-key-pair --key-name novatrix-v44-key 2>/dev/null || true
rm -f novatrix-v44-key.pem

echo "==> 3/4 Natverksstacken $STACK (VPC, subnat, NACL, SG, flow logs)"
# Instansernas natverkskort maste vara borta innan security groups kan tas bort,
# darfor vantade vi pa 'terminated' ovan
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK" && echo "    borttagen"

echo "==> 4/4 IAM och S3 fran v43"
if [ "${1:-}" = "--behall-iam" ]; then
  echo "    behalls (--behall-iam)"
else
  bash ../../v43/scripts/teardown.sh
fi
