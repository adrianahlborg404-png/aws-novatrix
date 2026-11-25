#!/bin/bash
# =============================================================
# teardown.sh - Novatrix AB, AWS v46
# Tar bort hela miljon i omvand ordning: webb -> data -> natverk.
# Ordningen kravs: en stack vars exports anvands av en annan
# gar inte att radera forran den andra ar borta.
#
#   bash teardown.sh
#   bash teardown.sh -p ../parametrar/novatrix-test.env
#
# Det enda som behover goras fore CloudFormation ar att tomma
# backup-bucketen, eftersom en bucket med filer inte kan raderas.
# RDS tar 5-10 minuter att ta bort.
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")" || exit 1

PARAMFIL="../parametrar/novatrix.env"
if [ "${1:-}" = "-p" ]; then PARAMFIL="$2"; shift 2; fi
# shellcheck source=../parametrar/novatrix.env
source "$PARAMFIL"
echo "Miljo: $PREFIX"

ta_bort() {  # stack
  if aws cloudformation describe-stacks --stack-name "$1" >/dev/null 2>&1; then
    aws cloudformation delete-stack --stack-name "$1"
    aws cloudformation wait stack-delete-complete --stack-name "$1" \
      && echo "    borttagen" || echo "    FEL: se describe-stack-events for $1"
  else
    echo "    finns inte"
  fi
}

echo "==> 1/4 Tommer backup-bucketen"
BUCKET=$(aws cloudformation describe-stacks --stack-name "$PREFIX-data" \
  --query "Stacks[0].Outputs[?OutputKey=='BackupBucket'].OutputValue" --output text 2>/dev/null || true)
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  aws s3 rm "s3://${BUCKET}" --recursive --only-show-errors && echo "    tommd"
fi

echo "==> 2/4 Webbstacken $PREFIX-webb (servrar, roll, key pair)"
ta_bort "$PREFIX-webb"
rm -f "${PREFIX}-key.pem"

echo "==> 3/4 Datastacken $PREFIX-data (RDS, EFS, S3, hemligheten), 5-10 min"
ta_bort "$PREFIX-data"

echo "==> 4/4 Natverksstacken $PREFIX-natverk"
ta_bort "$PREFIX-natverk"

KVAR=0
for lager in natverk data webb; do
  aws cloudformation describe-stacks --stack-name "$PREFIX-$lager" >/dev/null 2>&1 && KVAR=$((KVAR+1))
done
echo "==> Klart. Kvar av miljon $PREFIX: $KVAR av 3 stackar"
