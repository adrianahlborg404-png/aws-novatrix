#!/bin/bash
# =============================================================
# verify.sh - Novatrix AB, AWS v43
# Testar behorigheterna pa riktigt: kor AWS-anrop SOM anna-drift,
# erik-utv, novatrix-deploy-role och EC2-rollen och jamfor med
# vad som forvantas. Anvandarna far tillfalliga nycklar som tas
# bort automatiskt nar skriptet ar klart.
#
#   bash verify.sh
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"

KONTO=$(aws sts get-caller-identity --query Account --output text)
BUCKET="novatrix-webb-${KONTO}"
DEPLOY_ROLL="arn:aws:iam::${KONTO}:role/novatrix-deploy-role"

INSTANS_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values=novatrix-web-v43 Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
PUBLIK_IP=$(aws ec2 describe-instances --instance-ids "$INSTANS_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
[ "$INSTANS_ID" != "None" ] || { echo "Ingen instans igang. Kor deploy.sh forst."; exit 1; }

# ---------- hjalpfunktioner ----------
OK=0; FEL=0
resultat() {  # beskrivning forvantat faktiskt
  local s="OK"
  if [ "$2" = "$3" ]; then OK=$((OK+1)); else s="FEL"; FEL=$((FEL+1)); fi
  printf "  %-48s forvantat %-9s fick %-9s [%s]\n" "$1" "$2" "$3" "$s"
}
kor()     { if "$@" >/dev/null 2>&1; then echo "TILLATET"; else echo "NEKAT"; fi; }
# --dry-run: AWS svarar DryRunOperation om anropet hade fatt ga igenom, annars UnauthorizedOperation
torrkor() {
  local ut; ut=$("$@" --dry-run 2>&1)
  if [[ "$ut" == *DryRunOperation* ]]; then echo "TILLATET"; else echo "NEKAT"; fi
}

# som: kor aws med credentials i AK/SK (och ST for en roll)
som() {
  if [ -n "${ST:-}" ]; then
    AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" aws "$@"
  else
    env -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws "$@"
  fi
}

NYCKLAR=()
stada() {
  for n in "${NYCKLAR[@]}"; do
    aws iam delete-access-key --user-name "${n%%:*}" --access-key-id "${n##*:}"
  done
  [ ${#NYCKLAR[@]} -gt 0 ] && echo "==> Tillfalliga nycklar borttagna"
}
trap stada EXIT

logga_in_som() {  # anvandare -> satter AK och SK
  ST=""
  read -r AK SK < <(aws iam create-access-key --user-name "$1" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
  NYCKLAR+=("$1:$AK")
  for i in $(seq 1 10); do som sts get-caller-identity >/dev/null 2>&1 && return; sleep 3; done
}

# ---------- 1. EC2-instansens roll ----------
echo ""
echo "==> 1/4 EC2-instansen (novatrix-web-role), resultat fran user data:"
curl -s "http://${PUBLIK_IP}/iam-test.txt" | sed 's/^/  /'

# ---------- 2. anna-drift ----------
echo ""
echo "==> 2/4 anna-drift (grupp novatrix-drift)"
logga_in_som anna-drift
resultat "Lista EC2-instanser i Stockholm"      TILLATET "$(kor som ec2 describe-instances)"
resultat "Lista EC2-instanser i us-east-1"      NEKAT    "$(kor som ec2 describe-instances --region us-east-1)"
resultat "Stoppa Novatrix-instansen (dry-run)"  TILLATET "$(torrkor som ec2 stop-instances --instance-ids "$INSTANS_ID")"
resultat "Terminera instansen (dry-run)"        NEKAT    "$(torrkor som ec2 terminate-instances --instance-ids "$INSTANS_ID")"
resultat "Lasa S3-bucketen"                     NEKAT    "$(kor som s3 ls "s3://${BUCKET}/webb/")"
resultat "Anta novatrix-deploy-role"            NEKAT    "$(kor som sts assume-role --role-arn "$DEPLOY_ROLL" --role-session-name test)"

# ---------- 3. erik-utv och deploy-rollen ----------
echo ""
echo "==> 3/4 erik-utv (grupp novatrix-utveckling)"
logga_in_som erik-utv
resultat "Lasa S3-bucketen direkt"              NEKAT    "$(kor som s3 ls "s3://${BUCKET}/webb/")"
resultat "Lista EC2-instanser"                  NEKAT    "$(kor som ec2 describe-instances)"
read -r RAK RSK RST < <(som sts assume-role --role-arn "$DEPLOY_ROLL" \
  --role-session-name erik-deploy \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null)
resultat "Anta novatrix-deploy-role"            TILLATET "$([ -n "${RAK:-}" ] && echo TILLATET || echo NEKAT)"

echo ""
echo "    ...som novatrix-deploy-role (session erik-deploy)"
AK="${RAK:-x}"; SK="${RSK:-x}"; ST="${RST:-x}"
STAMPEL="Uppdaterad av erik-utv via novatrix-deploy-role $(date +%H:%M:%S)"
TMP=$(mktemp)
som s3 cp "s3://${BUCKET}/webb/index.html" "$TMP" >/dev/null 2>&1
sed -i "s|</body>|<p style=\"text-align:center\">${STAMPEL}</p>\n</body>|" "$TMP"
resultat "Lista webb/ i S3"                     TILLATET "$(kor som s3 ls "s3://${BUCKET}/webb/")"
resultat "Ladda upp ny webb/index.html"         TILLATET "$(kor som s3 cp "$TMP" "s3://${BUCKET}/webb/index.html")"
resultat "Skriva utanfor webb/ (annat.txt)"     NEKAT    "$(kor som s3 cp "$TMP" "s3://${BUCKET}/annat.txt")"
resultat "Radera webb/index.html"               NEKAT    "$(kor som s3api delete-object --bucket "$BUCKET" --key webb/index.html)"
resultat "Lista EC2-instanser"                  NEKAT    "$(kor som ec2 describe-instances)"
resultat "Lista IAM-anvandare"                  NEKAT    "$(kor som iam list-users)"
rm -f "$TMP"

# ---------- 4. Hela kedjan ----------
echo ""
echo "==> 4/4 Kedjan erik-utv -> deploy-roll -> S3 -> EC2-roll -> webbsida"
echo "    Vantar pa att instansen synkar fran S3 (upp till 90 s)..."
SYNKAD="NEKAT"
for i in $(seq 1 18); do
  if curl -s "http://${PUBLIK_IP}" | grep -q "$STAMPEL"; then SYNKAD="TILLATET"; break; fi
  sleep 5
done
resultat "Ny text syns pa http://${PUBLIK_IP}"  TILLATET "$SYNKAD"

echo ""
echo "==> Sammanfattning: ${OK} OK, ${FEL} FEL"
