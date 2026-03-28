#!/bin/bash

# SCHRITT 9: Network ACLs verwalten
# Übersicht, Regeln hinzufügen/entfernen
#
# Unterschied zu Security Groups:
#   - ACL wirkt auf Subnetz-Ebene (nicht Instanz)
#   - Stateless: Eingehend UND ausgehend müssen separat erlaubt werden
#   - Regeln haben Priorität (Nummer) – niedrigste Nummer gewinnt
#   - Explizite DENY-Regeln möglich

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/01_output.env" 2>/dev/null
[ -z "$REGION" ] && REGION="us-east-1"

# ─── Übersicht ────────────────────────────────────────────────────────────────
show_overview() {
    echo -e "${BOLD}─── Network ACLs im VPC ─────────────────────────────${NC}"
    echo -e "${DIM}  Stateless: Eingehend + Ausgehend müssen separat konfiguriert werden.${NC}"
    echo -e "${DIM}  Priorität: Niedrigste Regel-Nummer gewinnt. Regel 100 vor Regel 200.${NC}"
    echo ""

    ACL_LIST=$(aws ec2 describe-network-acls \
        --query "NetworkAcls[].{ID:NetworkAclId,Default:IsDefault,VpcId:VpcId,Subnets:Associations[].SubnetId}" \
        --output json --region "$REGION" 2>/dev/null)

    ACL_COUNT=$(echo "$ACL_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

    ACL_IDS_LIST=()
    ACL_IDS_LIST[0]=""

    for ((i=0; i<ACL_COUNT; i++)); do
        ACL_ID=$(echo "$ACL_LIST" | python3 -c "import sys,json; print(json.load(sys.stdin)[$i]['ID'])" 2>/dev/null)
        IS_DEFAULT=$(echo "$ACL_LIST" | python3 -c "import sys,json; print(json.load(sys.stdin)[$i]['Default'])" 2>/dev/null)
        ACL_VPC=$(echo "$ACL_LIST" | python3 -c "import sys,json; print(json.load(sys.stdin)[$i]['VpcId'])" 2>/dev/null)
        ACL_IDS_LIST[$i]="$ACL_ID"

        DEFAULT_LABEL=""
        [ "$IS_DEFAULT" == "True" ] && DEFAULT_LABEL="${DIM} [Standard-ACL]${NC}"

        echo -e "  ${CYAN}[$((i+1))]${NC} ${BOLD}$ACL_ID${NC}$DEFAULT_LABEL  ${DIM}VPC: $ACL_VPC${NC}"

        # Zugeordnete Subnetze
        SUBNET_IDS=$(echo "$ACL_LIST" | python3 -c "
import sys,json
acl=json.load(sys.stdin)[$i]
subnets=acl.get('Subnets',[])
print('\n'.join(s for s in subnets if s))
" 2>/dev/null)

        if [ -n "$SUBNET_IDS" ]; then
            while IFS= read -r SID; do
                [ -z "$SID" ] && continue
                SNAME=""
                for ((n=1; n<=SUBNET_COUNT; n++)); do
                    SID_VAR="SUBNET_ID_$n"; SN_NAME_VAR="SN_NAME_$n"; SN_CIDR_VAR="SN_CIDR_$n"
                    if [ "${!SID_VAR}" == "$SID" ]; then
                        SNAME="${!SN_NAME_VAR} (${!SN_CIDR_VAR})"
                        break
                    fi
                done
                echo -e "      ${DIM}↳ Subnetz: ${SNAME:-$SID}${NC}"
            done <<< "$SUBNET_IDS"
        else
            echo -e "      ${DIM}↳ Kein Subnetz zugeordnet${NC}"
        fi

        # Inbound-Regeln  (text-Output alphabetisch: Action,CIDR,From,Nr,Proto,To)
        echo -e "      ${DIM}Inbound:${NC}"
        aws ec2 describe-network-acls --network-acl-ids "$ACL_ID" \
            --query "NetworkAcls[0].Entries[?Egress==\`false\`]|sort_by(@,&RuleNumber)[].{Action:RuleAction,CIDR:CidrBlock,From:PortRange.From,Nr:RuleNumber,Proto:Protocol,To:PortRange.To}" \
            --output text --region "$REGION" 2>/dev/null | \
        while IFS=$'\t' read -r ACTION CIDR FROM NR PROTO TO; do
            [ -z "$NR" ] && continue
            [ "$ACTION" == "allow" ] && A="${GREEN}ALLOW${NC}" || A="${RED}DENY${NC}"
            [ "$PROTO" == "-1" ] && PORT_INFO="Alle" || PORT_INFO="Port $FROM${TO:+-$TO}"
            [ "$NR" == "32767" ] && A="${RED}DENY${NC}" && PORT_INFO="Alle (Standard)"
            echo -e "      ${DIM}  Regel $NR: $A  $PORT_INFO  von  $CIDR${NC}"
        done

        # Outbound-Regeln  (text-Output alphabetisch: Action,CIDR,From,Nr,Proto,To)
        echo -e "      ${DIM}Outbound:${NC}"
        aws ec2 describe-network-acls --network-acl-ids "$ACL_ID" \
            --query "NetworkAcls[0].Entries[?Egress==\`true\`]|sort_by(@,&RuleNumber)[].{Action:RuleAction,CIDR:CidrBlock,From:PortRange.From,Nr:RuleNumber,Proto:Protocol,To:PortRange.To}" \
            --output text --region "$REGION" 2>/dev/null | \
        while IFS=$'\t' read -r ACTION CIDR FROM NR PROTO TO; do
            [ -z "$NR" ] && continue
            [ "$ACTION" == "allow" ] && A="${GREEN}ALLOW${NC}" || A="${RED}DENY${NC}"
            [ "$PROTO" == "-1" ] && PORT_INFO="Alle" || PORT_INFO="Port $FROM${TO:+-$TO}"
            [ "$NR" == "32767" ] && A="${RED}DENY${NC}" && PORT_INFO="Alle (Standard)"
            echo -e "      ${DIM}  Regel $NR: $A  $PORT_INFO  nach  $CIDR${NC}"
        done

        echo ""
    done
}

# ─── ACL auswählen ────────────────────────────────────────────────────────────
select_acl() {
    show_overview
    read -rp "Network ACL auswählen [Nummer]: " SEL
    local IDX=$(( SEL - 1 ))
    SELECTED_ACL_ID="${ACL_IDS_LIST[$IDX]}"
    if [ -z "$SELECTED_ACL_ID" ]; then
        echo -e "${RED}Ungültige Auswahl.${NC}"; return 1
    fi
    echo -e "  Gewählt: ${CYAN}$SELECTED_ACL_ID${NC}"
    echo ""
}

# ─── Regel hinzufügen ─────────────────────────────────────────────────────────
add_rule() {
    select_acl || return

    echo -e "${BOLD}─── Neue ACL-Regel ──────────────────────────────────${NC}"
    echo -e "${DIM}  Tipp: Niedrigere Nummer = höhere Priorität (z.B. 100 vor 200)${NC}"
    echo -e "${DIM}  Regel 32767 = Standard-DENY (immer vorhanden, nicht löschbar)${NC}"
    echo ""

    # Richtung
    echo -e "  Richtung:"
    echo -e "    [1] Inbound  (eingehender Traffic)"
    echo -e "    [2] Outbound (ausgehender Traffic)"
    read -rp "  Auswahl [1]: " DIR_SEL
    [ "${DIR_SEL:-1}" == "2" ] && EGRESS="true" || EGRESS="false"

    # Regel-Nummer
    read -rp "  Regel-Nummer (z.B. 100, 200): " RULE_NR
    if ! [[ "$RULE_NR" =~ ^[0-9]+$ ]] || [ "$RULE_NR" -lt 1 ] || [ "$RULE_NR" -gt 32766 ]; then
        echo -e "${RED}Ungültige Nummer (1-32766).${NC}"; return
    fi

    # Aktion
    echo -e "  Aktion:"
    echo -e "    [1] ALLOW  – Traffic erlauben"
    echo -e "    [2] DENY   – Traffic blockieren"
    read -rp "  Auswahl [1]: " ACTION_SEL
    [ "${ACTION_SEL:-1}" == "2" ] && ACTION="deny" || ACTION="allow"

    # Typ-Auswahl wie in der AWS-Konsole
    echo -e "  Typ:"
    echo -e "    ${DIM}── Häufig verwendet ──────────────────${NC}"
    echo -e "    [1]  All traffic          (alle Protokolle)"
    echo -e "    [2]  All ICMP - IPv4      (Ping + alle ICMP-Nachrichten)"
    echo -e "    [3]  Custom ICMP - IPv4   (bestimmter ICMP-Typ, z.B. Echo)"
    echo -e "    [4]  SSH                  TCP 22"
    echo -e "    [5]  HTTP                 TCP 80"
    echo -e "    [6]  HTTPS                TCP 443"
    echo -e "    [7]  RDP                  TCP 3389"
    echo -e "    ${DIM}── Datenbanken ───────────────────────${NC}"
    echo -e "    [8]  MySQL / Aurora        TCP 3306"
    echo -e "    [9]  PostgreSQL            TCP 5432"
    echo -e "    [10] MS SQL                TCP 1433"
    echo -e "    ${DIM}── Benutzerdefiniert ─────────────────${NC}"
    echo -e "    [11] Custom TCP            Port-Bereich"
    echo -e "    [12] Custom UDP            Port-Bereich"
    echo ""
    read -rp "  Auswahl: " TYPE_SEL

    PROTO="" ; PORT_ARGS="" ; ICMP_ARGS="" ; RULE_LABEL=""
    case "${TYPE_SEL}" in
        1)  PROTO="-1";  RULE_LABEL="All traffic" ;;
        2)  PROTO="1";   ICMP_ARGS="--icmp-type-code Type=-1,Code=-1"; RULE_LABEL="All ICMP - IPv4" ;;
        3)  PROTO="1"
            echo ""
            echo -e "  ICMP-Typ:"
            echo -e "    [1] Echo Request  (Ping senden,  Type 8)"
            echo -e "    [2] Echo Reply    (Ping Antwort, Type 0)"
            echo -e "    [3] Destination Unreachable (Type 3)"
            echo -e "    [4] Time Exceeded (Traceroute, Type 11)"
            echo -e "    [5] Custom"
            read -rp "  Auswahl [1]: " ICMP_SEL
            case "${ICMP_SEL:-1}" in
                1) ICMP_T="8";  ICMP_C="-1"; RULE_LABEL="ICMP Echo Request (Ping)" ;;
                2) ICMP_T="0";  ICMP_C="-1"; RULE_LABEL="ICMP Echo Reply" ;;
                3) ICMP_T="3";  ICMP_C="-1"; RULE_LABEL="ICMP Destination Unreachable" ;;
                4) ICMP_T="11"; ICMP_C="-1"; RULE_LABEL="ICMP Time Exceeded" ;;
                5) read -rp "  ICMP Type (0-255): " ICMP_T
                   read -rp "  ICMP Code [-1=alle]: " ICMP_C
                   ICMP_C="${ICMP_C:--1}"
                   RULE_LABEL="Custom ICMP Type $ICMP_T Code $ICMP_C" ;;
                *) ICMP_T="8"; ICMP_C="-1"; RULE_LABEL="ICMP Echo Request (Ping)" ;;
            esac
            ICMP_ARGS="--icmp-type-code Type=$ICMP_T,Code=$ICMP_C" ;;
        4)  PROTO="6";  PORT_ARGS="--port-range From=22,To=22";   RULE_LABEL="SSH (TCP 22)" ;;
        5)  PROTO="6";  PORT_ARGS="--port-range From=80,To=80";   RULE_LABEL="HTTP (TCP 80)" ;;
        6)  PROTO="6";  PORT_ARGS="--port-range From=443,To=443"; RULE_LABEL="HTTPS (TCP 443)" ;;
        7)  PROTO="6";  PORT_ARGS="--port-range From=3389,To=3389"; RULE_LABEL="RDP (TCP 3389)" ;;
        8)  PROTO="6";  PORT_ARGS="--port-range From=3306,To=3306"; RULE_LABEL="MySQL/Aurora (TCP 3306)" ;;
        9)  PROTO="6";  PORT_ARGS="--port-range From=5432,To=5432"; RULE_LABEL="PostgreSQL (TCP 5432)" ;;
        10) PROTO="6";  PORT_ARGS="--port-range From=1433,To=1433"; RULE_LABEL="MS SQL (TCP 1433)" ;;
        11) PROTO="6"
            read -rp "  Von Port: " PORT_FROM
            read -rp "  Bis Port [$PORT_FROM]: " PORT_TO
            PORT_TO="${PORT_TO:-$PORT_FROM}"
            PORT_ARGS="--port-range From=$PORT_FROM,To=$PORT_TO"
            RULE_LABEL="Custom TCP $PORT_FROM${PORT_TO:+-$PORT_TO}" ;;
        12) PROTO="17"
            read -rp "  Von Port: " PORT_FROM
            read -rp "  Bis Port [$PORT_FROM]: " PORT_TO
            PORT_TO="${PORT_TO:-$PORT_FROM}"
            PORT_ARGS="--port-range From=$PORT_FROM,To=$PORT_TO"
            RULE_LABEL="Custom UDP $PORT_FROM${PORT_TO:+-$PORT_TO}" ;;
        *)  echo -e "${RED}Ungültige Auswahl.${NC}"; return ;;
    esac

    # CIDR
    echo -e "  CIDR:"
    echo -e "    [1] Alle  (0.0.0.0/0)"
    echo -e "    [2] Nur VPC  ($VPC_CIDR)"
    echo -e "    [3] Eigene eingeben"
    read -rp "  Auswahl [1]: " CIDR_SEL
    case "${CIDR_SEL:-1}" in
        2) CIDR="$VPC_CIDR" ;;
        3) read -rp "  CIDR: " CIDR ;;
        *) CIDR="0.0.0.0/0" ;;
    esac

    [ "$EGRESS" == "true" ] && DIR_LABEL="Outbound" || DIR_LABEL="Inbound"
    [ "$ACTION" == "allow" ] && ACT_LABEL="${GREEN}ALLOW${NC}" || ACT_LABEL="${RED}DENY${NC}"

    echo ""
    echo -e "  Neue Regel: $DIR_LABEL  Regel $RULE_NR  $ACT_LABEL  ${CYAN}$RULE_LABEL${NC}  von/nach  ${CYAN}$CIDR${NC}"
    read -rp "  Hinzufügen? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return

    RESULT=$(aws ec2 create-network-acl-entry \
        --network-acl-id "$SELECTED_ACL_ID" \
        --rule-number "$RULE_NR" \
        --protocol "$PROTO" \
        --rule-action "$ACTION" \
        --cidr-block "$CIDR" \
        $( [ "$EGRESS" == "true" ] && echo "--egress" || echo "--ingress" ) \
        $PORT_ARGS $ICMP_ARGS \
        --region "$REGION" 2>&1)

    if echo "$RESULT" | grep -q "NetworkAclEntryAlreadyExists"; then
        echo -e "  ${YELLOW}Regel $RULE_NR existiert bereits. Andere Nummer wählen.${NC}"
    elif echo "$RESULT" | grep -q "error\|Error"; then
        echo -e "  ${RED}Fehler: $RESULT${NC}"
    else
        echo -e "  ${GREEN}✓ Regel $RULE_NR ($RULE_LABEL) hinzugefügt${NC}"
    fi
}

# ─── Regel entfernen ──────────────────────────────────────────────────────────
remove_rule() {
    select_acl || return

    echo -e "${BOLD}─── Regel entfernen ─────────────────────────────────${NC}"
    echo ""

    echo -e "  Richtung:"
    echo -e "    [1] Inbound"
    echo -e "    [2] Outbound"
    read -rp "  Auswahl [1]: " DIR_SEL
    [ "${DIR_SEL:-1}" == "2" ] && EGRESS="true" || EGRESS="false"
    [ "$EGRESS" == "true" ] && DIR_LABEL="Outbound" || DIR_LABEL="Inbound"

    echo ""
    echo -e "  Bestehende $DIR_LABEL-Regeln:"
    aws ec2 describe-network-acls --network-acl-ids "$SELECTED_ACL_ID" \
        --query "NetworkAcls[0].Entries[?Egress==\`$EGRESS\`]|sort_by(@,&RuleNumber)[].{Action:RuleAction,CIDR:CidrBlock,Nr:RuleNumber,Proto:Protocol}" \
        --output text --region "$REGION" 2>/dev/null | \
    while IFS=$'\t' read -r ACTION CIDR NR PROTO; do
        [ -z "$NR" ] && continue
        [ "$ACTION" == "allow" ] && A="${GREEN}ALLOW${NC}" || A="${RED}DENY${NC}"
        [ "$NR" == "32767" ] && echo -e "    Regel $NR: $A  Alle  (Standard – nicht löschbar)" && continue
        echo -e "    Regel $NR: $A  Protokoll $PROTO  $CIDR"
    done

    echo ""
    read -rp "  Regel-Nummer zum Entfernen: " RULE_NR
    [ "$RULE_NR" == "32767" ] && echo -e "${RED}Standard-Regel kann nicht entfernt werden.${NC}" && return

    echo -e "  Entferne: $DIR_LABEL Regel $RULE_NR aus $SELECTED_ACL_ID"
    read -rp "  Wirklich entfernen? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return

    RESULT=$(aws ec2 delete-network-acl-entry \
        --network-acl-id "$SELECTED_ACL_ID" \
        --rule-number "$RULE_NR" \
        $( [ "$EGRESS" == "true" ] && echo "--egress" || echo "--ingress" ) \
        --region "$REGION" 2>&1)

    if echo "$RESULT" | grep -q "error\|Error"; then
        echo -e "  ${RED}Fehler: $RESULT${NC}"
    else
        echo -e "  ${GREEN}✓ Regel $RULE_NR entfernt${NC}"
    fi
}

# ─── Hauptmenü ────────────────────────────────────────────────────────────────
while true; do
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           Network ACLs verwalten                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${DIM}  ACL = Subnetz-Firewall | SG = Instanz-Firewall${NC}"
    echo -e "${DIM}  ACL ist stateless: Inbound UND Outbound separat konfigurieren!${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC} Übersicht anzeigen"
    echo -e "  ${CYAN}[2]${NC} Regel hinzufügen"
    echo -e "  ${CYAN}[3]${NC} Regel entfernen"
    echo -e "  ${CYAN}[0]${NC} Zurück"
    echo ""
    read -rp "Auswahl: " CHOICE

    case "$CHOICE" in
        1) clear; show_overview; read -rp "Enter zum Fortfahren..." ;;
        2) clear; add_rule; read -rp "Enter zum Fortfahren..." ;;
        3) clear; remove_rule; read -rp "Enter zum Fortfahren..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ungültige Auswahl.${NC}"; sleep 1 ;;
    esac
done
