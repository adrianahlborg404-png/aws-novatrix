#!/bin/bash
# =============================================================
# andring.sh - Novatrix AB, AWS v46
# Gor en andring sakert: visa FORST vad som kommer att handa, kor
# sedan. Arbetsgangen for en andring (Delmoment 4):
#   1. Andra mallen i repot, committa och pusha
#   2. git pull i CloudShell
#   3. bash andring.sh <lager>  -> change set: Add/Modify/Remove och
#      om nagon resurs ersatts (Replacement), innan nagot rors
#   4. j = kor andringen, n = kasta change setet
#
#   bash andring.sh webb
#   bash andring.sh data RdsBackupDays=0          # andra en parameter
#   bash andring.sh natverk -p ../parametrar/novatrix-test.env
# =============================================================
set -euo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")"

LAGER="${1:-}"
case "$LAGER" in
  natverk|data|webb) shift ;;
  *) echo "Anvandning: bash andring.sh <natverk|data|webb> [-p parameterfil] [Parameter=Varde ...]"; exit 1 ;;
esac
PARAMFIL="../parametrar/novatrix.env"
if [ "${1:-}" = "-p" ]; then PARAMFIL="$2"; shift 2; fi
# shellcheck source=../parametrar/novatrix.env
source "$PARAMFIL"
STACK="$PREFIX-$LAGER"
MALL="../cloudformation/$LAGER.yaml"
NAMN="andring-$(date +%Y%m%d-%H%M%S)"

echo "==> Mallen $LAGER.yaml, senaste commits i Git:"
git log -3 --format='    %h %ad %s' --date=short -- "$MALL" 2>/dev/null || echo "    (inte ett Git-repo)"

echo "==> Validerar mallen"
aws cloudformation validate-template --template-body "file://$MALL" >/dev/null && echo "    OK"

# Parametrar: behall nuvarande varden i stacken, utom de som anges
PARAMS=()
for k in $(aws cloudformation describe-stacks --stack-name "$STACK" \
             --query 'Stacks[0].Parameters[].ParameterKey' --output text); do
  NYTT=""
  for a in "$@"; do [[ "$a" == "$k="* ]] && NYTT="${a#*=}"; done
  if [ -n "$NYTT" ]; then
    PARAMS+=("ParameterKey=$k,ParameterValue=$NYTT"); echo "    $k = $NYTT (nytt varde)"
  else
    PARAMS+=("ParameterKey=$k,UsePreviousValue=true")
  fi
done

echo "==> Skapar change set $NAMN for $STACK"
aws cloudformation create-change-set \
  --stack-name "$STACK" \
  --change-set-name "$NAMN" \
  --template-body "file://$MALL" \
  --parameters "${PARAMS[@]}" \
  --capabilities CAPABILITY_NAMED_IAM >/dev/null
if ! aws cloudformation wait change-set-create-complete --stack-name "$STACK" --change-set-name "$NAMN" 2>/dev/null; then
  echo "    $(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$NAMN" \
    --query StatusReason --output text)"
  aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$NAMN"
  echo "    Inget att andra, change setet borttaget."
  exit 0
fi

echo ""
echo "    Det har kommer att handa (Replacement True = resursen ersatts av en ny):"
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$NAMN" \
  --query 'Changes[].ResourceChange.{Atgard:Action,Resurs:LogicalResourceId,Typ:ResourceType,Ersatts:Replacement}' \
  --output table
echo ""
read -r -p "    Kor andringen nu? (j/n) " SVAR
if [ "$SVAR" = "j" ]; then
  aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name "$NAMN"
  echo "    Kor... (vantar tills $STACK ar klar)"
  aws cloudformation wait stack-update-complete --stack-name "$STACK"
  echo "    Klart: $(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text)"
  echo "    Handelserna: aws cloudformation describe-stack-events --stack-name $STACK --max-items 15"
else
  aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$NAMN"
  echo "    Ingen andring gjord, change setet borttaget."
fi
