#!/bin/bash
# =============================================================
# verify.sh - Novatrix AB, AWS v44
# Testar pa riktigt vilken trafik som slapps igenom och vilken
# som blockeras: fran internet, inifran via bastion, ett skydds-
# lager i taget, och att de privata subnaten saknar internetvag.
#
#   bash verify.sh
#
# TILLATET = TCP-anslutningen gick fram
# BLOCKERAT = timeout, paketet slangdes tyst av NACL eller SG
# STANGD   = natet slappte fram men ingen tjanst lyssnar (RST)
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"
cd "$(dirname "$0")"

STACK="novatrix-natverk-v44"
KEY_FIL="$(pwd)/novatrix-v44-key.pem"

ut() { aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null; }
VPC_ID=$(ut VpcId)
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || { echo "Stacken $STACK saknas. Kor deploy.sh forst."; exit 1; }
WEB_SG=$(ut WebSgId); WEB_NACL=$(ut WebNaclId); DB_SG=$(ut DbSgId)
DB_PORT=$(ut DbPort); ADMIN_IP=$(ut AdminIp); PRIV_RT=$(ut PrivateRouteTableId)

instans() {  # namn falt
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$2" --output text
}
WEB_IP=$(instans novatrix-web-v44 PublicIpAddress)
WEB_PRIV=$(instans novatrix-web-v44 PrivateIpAddress)
BASTION_IP=$(instans novatrix-bastion-v44 PublicIpAddress)
BASTION_PRIV=$(instans novatrix-bastion-v44 PrivateIpAddress)
[ "$WEB_IP" != "None" ] && [ "$BASTION_IP" != "None" ] || { echo "Instanserna kor inte. Kor deploy.sh."; exit 1; }
CS_IP=$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')

# ---------- hjalpfunktioner ----------
OK=0; FEL=0
resultat() {  # beskrivning forvantat faktiskt
  local s="OK"
  if [ "$2" = "$3" ]; then OK=$((OK+1)); else s="FEL"; FEL=$((FEL+1)); fi
  printf "  %-50s forvantat %-9s fick %-9s [%s]\n" "$1" "$2" "$3" "$s"
}

# Samma TCP-test lokalt och pa servrarna (skickas som text over SSH)
TCP_TEST='t(){ out=$(timeout 4 bash -c "</dev/tcp/$1/$2" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo TILLATET; elif [ $rc -eq 124 ]; then echo BLOCKERAT
  elif [[ $out == *refused* ]]; then echo STANGD; else echo BLOCKERAT; fi; }; t'
tcp() { bash -c "$TCP_TEST \"\$@\"" _ "$1" "$2"; }

http_test() {  # url -> TILLATET om svar 200
  local kod; kod=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "$1")
  [ "$kod" = "200" ] && echo TILLATET || echo BLOCKERAT
}

# Vanta in en natverksandring: testa om tills vantat resultat (max ca 30 s)
vanta_tcp() {  # vantat host port
  local r
  for _ in 1 2 3 4 5 6; do r=$(tcp "$2" "$3"); [ "$r" = "$1" ] && break; sleep 5; done
  echo "$r"
}

SSH_OPT=(-i "$KEY_FIL" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes)
pa_bastion() { ssh "${SSH_OPT[@]}" "ec2-user@$BASTION_IP" "$@"; }
# Nyckeln stannar i CloudShell: bastion vidarebefordrar bara TCP (-W), den far aldrig nyckeln
pa_webb() { ssh "${SSH_OPT[@]}" -o ProxyCommand="ssh ${SSH_OPT[*]} -W %h:%p ec2-user@$BASTION_IP" \
  "ec2-user@$WEB_PRIV" "$@"; }

# Tillfalliga regler i steg 4 tas alltid bort, aven om skriptet avbryts
SG_OPPEN=0; NACL_OPPEN=0
stada() {
  [ "$SG_OPPEN" = 1 ] && aws ec2 revoke-security-group-ingress --group-id "$WEB_SG" \
    --protocol tcp --port 22 --cidr "${CS_IP}/32" >/dev/null 2>&1
  [ "$NACL_OPPEN" = 1 ] && aws ec2 delete-network-acl-entry --network-acl-id "$WEB_NACL" \
    --ingress --rule-number 90 >/dev/null 2>&1
  [ "$SG_OPPEN$NACL_OPPEN" != "00" ] && echo "==> Tillfalliga testregler borttagna"
  return 0
}
trap stada EXIT

echo "Novatrix v44 - verifiering av natverket, $(date '+%Y-%m-%d %H:%M')"
echo "Webb $WEB_IP ($WEB_PRIV) | Bastion $BASTION_IP ($BASTION_PRIV)"
echo "CloudShell-IP $CS_IP | Admin-IP i stacken $ADMIN_IP"

echo ""
echo "    Vantar pa att webbservern svarar (user data, max 3 min)..."
for _ in $(seq 1 36); do [ "$(http_test "http://$WEB_IP")" = TILLATET ] && break; sleep 5; done

# ---------- 1. Internet -> webbservern ----------
echo ""
echo "==> 1/5 Fran internet till webbservern"
resultat "HTTP  80  http://<webb>"                 TILLATET  "$(http_test "http://$WEB_IP")"
resultat "HTTPS 443 https://<webb> (sjalvsignerat)" TILLATET "$(http_test "https://$WEB_IP")"
resultat "SSH   22  direkt till webbservern"       BLOCKERAT "$(tcp "$WEB_IP" 22)"
resultat "DB    $DB_PORT direkt till webbservern"  BLOCKERAT "$(tcp "$WEB_IP" "$DB_PORT")"
resultat "Annan port 8080"                         BLOCKERAT "$(tcp "$WEB_IP" 8080)"

# ---------- 2. Internet -> bastion ----------
echo ""
echo "==> 2/5 Fran internet till bastion"
ADMIN=0; [ "$CS_IP" = "$ADMIN_IP" ] && ADMIN=1
if [ "$ADMIN" = 1 ]; then
  resultat "SSH 22 fran admin-IP (CloudShell)"     TILLATET  "$(tcp "$BASTION_IP" 22)"
else
  resultat "SSH 22 fran IP som inte ar admin-IP"   BLOCKERAT "$(tcp "$BASTION_IP" 22)"
fi
resultat "HTTP 80 till bastion"                    BLOCKERAT "$(tcp "$BASTION_IP" 80)"

# ---------- 3. Inifran via bastion ----------
echo ""
echo "==> 3/5 Inifran, via bastion"
if [ "$ADMIN" = 1 ] && [ -f "$KEY_FIL" ]; then
  r=$(pa_webb true >/dev/null 2>&1 && echo TILLATET || echo BLOCKERAT)
  resultat "SSH bastion -> webbserverns privata IP"  TILLATET  "$r"
  resultat "Bastion -> webb HTTP 80 (privat IP)"     BLOCKERAT "$(pa_bastion "$TCP_TEST $WEB_PRIV 80")"
  resultat "Bastion -> internet HTTPS 443"           BLOCKERAT "$(pa_bastion "$TCP_TEST s3.eu-north-1.amazonaws.com 443")"
  resultat "Webb -> internet HTTPS 443 (S3, dnf)"    TILLATET  "$(pa_webb "$TCP_TEST s3.eu-north-1.amazonaws.com 443")"
  resultat "Webb -> internet HTTP 80"                BLOCKERAT "$(pa_webb "$TCP_TEST checkip.amazonaws.com 80")"
  resultat "Webb -> internet SSH 22"                 BLOCKERAT "$(pa_webb "$TCP_TEST github.com 22")"
  resultat "Webb -> bastion SSH 22 (bakvagen)"       BLOCKERAT "$(pa_webb "$TCP_TEST $BASTION_PRIV 22")"
else
  echo "  Hoppar over: CloudShell ($CS_IP) ar inte admin-IP ($ADMIN_IP) eller nyckeln saknas."
  echo "  Kor 'bash deploy.sh' utan IP-argument for att gora CloudShell till admin-IP."
fi

# ---------- 4. Ett lager i taget ----------
echo ""
echo "==> 4/5 Defense in depth: SSH 22 till webbservern direkt fran CloudShell"
echo "    Simulerar felkonfiguration genom att tillfalligt oppna ett lager i taget"
aws ec2 authorize-security-group-ingress --group-id "$WEB_SG" \
  --protocol tcp --port 22 --cidr "${CS_IP}/32" >/dev/null && SG_OPPEN=1
sleep 5
resultat "a) SG oppen, NACL stangd -> NACL stoppar"  BLOCKERAT "$(tcp "$WEB_IP" 22)"

aws ec2 create-network-acl-entry --network-acl-id "$WEB_NACL" --ingress --rule-number 90 \
  --protocol tcp --port-range From=22,To=22 --cidr-block "${CS_IP}/32" --rule-action allow && NACL_OPPEN=1
resultat "b) Bada oppna (kontroll att testet fungerar)" TILLATET "$(vanta_tcp TILLATET "$WEB_IP" 22)"

aws ec2 revoke-security-group-ingress --group-id "$WEB_SG" \
  --protocol tcp --port 22 --cidr "${CS_IP}/32" >/dev/null && SG_OPPEN=0
resultat "c) NACL oppen, SG stangd -> SG stoppar"    BLOCKERAT "$(vanta_tcp BLOCKERAT "$WEB_IP" 22)"

aws ec2 delete-network-acl-entry --network-acl-id "$WEB_NACL" --ingress --rule-number 90 && NACL_OPPEN=0
echo "    Testreglerna borttagna, bada lagren ar stangda igen"

# ---------- 5. Privata subnat ----------
echo ""
echo "==> 5/5 Privata subnat for databasen (v45)"
VAGAR=$(aws ec2 describe-route-tables --route-table-ids "$PRIV_RT" \
  --query "length(RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'])" --output text)
resultat "Privat route table har vag till internet"  NEJ "$([ "$VAGAR" = 0 ] && echo NEJ || echo JA)"
PUBLIKA=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Niva,Values=privat" \
  --query "length(Subnets[?MapPublicIpOnLaunch])" --output text)
resultat "Privata subnat delar ut publik IP"         NEJ "$([ "$PUBLIKA" = 0 ] && echo NEJ || echo JA)"
KALLOR=$(aws ec2 describe-security-groups --group-ids "$DB_SG" \
  --query "SecurityGroups[0].IpPermissions[].[join(',',IpRanges[].CidrIp), join(',',UserIdGroupPairs[].GroupId)]" \
  --output text | tr -s '\t\n' ' ' | xargs)
resultat "db-sg slapper bara in webb-sg"             JA  "$([ "$KALLOR" = "$WEB_SG" ] && echo JA || echo NEJ)"

echo ""
echo "==> Sammanfattning: ${OK} OK, ${FEL} FEL"
echo "    Trafiken syns i flow logs inom ett par minuter: bash visa-trafik.sh"
