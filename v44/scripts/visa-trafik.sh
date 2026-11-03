#!/bin/bash
# =============================================================
# visa-trafik.sh - Novatrix AB, AWS v44
# Laser VPC Flow Logs och sammanfattar vad som slapptes igenom
# (ACCEPT) och vad som blockerades (REJECT) for webbservern och
# bastion. Andrar ingenting.
#
#   bash visa-trafik.sh [MINUTER]        (standard: senaste 30 min)
#   bash visa-trafik.sh 60 | tee trafik.txt
#
# Flow logs levereras med nagra minuters fordrojning.
# =============================================================
set -uo pipefail
export AWS_DEFAULT_REGION="eu-north-1"

MIN="${1:-30}"
LOGG="/novatrix/v44/flowlogs"
START=$(( ($(date +%s) - MIN * 60) * 1000 ))

instans() {  # namn falt
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" Name=instance-state-name,Values=running \
    --query "Reservations[0].Instances[0].$2" --output text
}
WEB_PRIV=$(instans novatrix-web-v44 PrivateIpAddress)
WEB_ENI=$(instans novatrix-web-v44 'NetworkInterfaces[0].NetworkInterfaceId')
BASTION_PRIV=$(instans novatrix-bastion-v44 PrivateIpAddress)
BASTION_ENI=$(instans novatrix-bastion-v44 'NetworkInterfaces[0].NetworkInterfaceId')

echo "Novatrix v44 - VPC Flow Logs, senaste $MIN minuterna ($(date '+%Y-%m-%d %H:%M'))"
echo "webb = $WEB_PRIV   bastion = $BASTION_PRIV   (flow logs visar privata IP:n)"

# Standardformatet: version konto eni src dst srcport dstport protokoll paket bytes start slut action status
aws logs filter-log-events --log-group-name "$LOGG" --start-time "$START" \
  --filter-pattern '[v, konto, eni, src, dst, sport, dport, proto, paket, bytes, start, slut, action, status=OK]' \
  --query 'events[].message' --output text | tr '\t' '\n' | awk \
  -v web="$WEB_PRIV" -v bas="$BASTION_PRIV" -v webeni="$WEB_ENI" -v baseni="$BASTION_ENI" '
  function namn(ip)  { return ip == web ? "webb" : (ip == bas ? "bastion" : "") }
  function server(e) { return e == webeni ? "webb" : (e == baseni ? "bastion" : "") }
  function egen(e)   { return e == webeni ? web : (e == baseni ? bas : "") }
  function proto(p)  { return p == 6 ? "tcp" : (p == 17 ? "udp" : (p == 1 ? "icmp" : p)) }
  function tjanst(p) {
    if (p == 22) return "ssh";    if (p == 80) return "http";  if (p == 443) return "https"
    if (p == 3306) return "mysql"; if (p == 5432) return "postgres"; if (p == 3389) return "rdp"
    if (p == 23) return "telnet"; if (p == 445) return "smb";   if (p == 8080) return "http-alt"
    return "-"
  }
  NF >= 14 {
    # Varje post loggas pa ett natverkskort (ENI): tolka den fran den serverns hall
    n = server($3); if (n == "") next
    # Inkommande: till servern. Svar pa serverns egna anrop (hog dport + ACCEPT) raknas inte.
    if ($5 == egen($3) && !($13 == "ACCEPT" && $7 >= 32768)) {
      k = n SUBSEP $13 SUBSEP proto($8) SUBSEP $7
      in_n[k]++; if (!((k, $4) in in_s)) { in_s[k, $4] = 1; in_u[k]++ }
    }
    # Utgaende: anslutningar som vara servrar sjalva startar (lag dport)
    if ($4 == egen($3) && $7 < 32768) {
      k = n SUBSEP $13 SUBSEP proto($8) SUBSEP $7 SUBSEP (namn($5) != "" ? namn($5) : $5)
      ut_n[k]++
    }
    rader++
  }
  END {
    printf "\nLaste %d flodesposter.\n", rader
    print "\n==> Inkommande till servrarna (topp 20)"
    printf "  %-8s %-7s %-10s %-9s %8s %13s\n", "Server", "Action", "Port", "Tjanst", "Floden", "Unika_kallor"
    for (k in in_n) { split(k, f, SUBSEP)
      printf "  %-8s %-7s %-10s %-9s %8d %13d\n", f[1], f[2], f[4] "/" f[3], tjanst(f[4]), in_n[k], in_u[k] | "sort -k5,5nr | head -20" }
    close("sort -k5,5nr | head -20")
    print "\n==> Utgaende fran servrarna"
    printf "  %-8s %-7s %-10s %-9s %-16s %8s\n", "Server", "Action", "Port", "Tjanst", "Mal", "Floden"
    for (k in ut_n) { split(k, f, SUBSEP)
      printf "  %-8s %-7s %-10s %-9s %-16s %8d\n", f[1], f[2], f[4] "/" f[3], tjanst(f[4]), f[5], ut_n[k] | "sort -k1,2 -k6,6nr" }
    close("sort -k1,2 -k6,6nr")
  }'

echo ""
echo "ACCEPT = slapptes igenom av bade NACL och security group."
echo "REJECT = stoppades av NACL eller security group. Det mesta inkommande"
echo "         ar skanningar fran internet mot portar som inte ar oppna."
