#!/bin/bash

# SCHRITT 8: Security Groups verwalten
# Übersicht, Regeln hinzufügen/entfernen

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/01_output.env" 2>/dev/null
source "$SCRIPT_DIR/02_output.env" 2>/dev/null

[ -z "$REGION" ] && REGION="us-east-1"

# ─── Übersicht anzeigen ───────────────────────────────────────────────────────
show_overview() {
    echo -e "${BOLD}─── Security Groups im VPC ──────────────────────────${NC}"
    echo ""

    SG_LIST=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[].{ID:GroupId,Name:GroupName}" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$SG_LIST" ]; then
        echo -e "  ${DIM}Keine Security Groups gefunden.${NC}"
        return
    fi

    local i=1
    declare -ga SG_IDS_LIST SG_NAMES_LIST
    SG_IDS_LIST=()
    SG_NAMES_LIST=()

    while IFS=$'\t' read -r SG_ID SG_NAME; do
        [ -z "$SG_ID" ] && continue
        SG_IDS_LIST+=("$SG_ID")
        SG_NAMES_LIST+=("$SG_NAME")

        echo -e "  ${CYAN}[$i]${NC} ${BOLD}$SG_NAME${NC}  ($SG_ID)"

        # Zugeordnete Instanzen
        INSTANCES=$(aws ec2 describe-instances \
            --filters "Name=instance.group-id,Values=$SG_ID" "Name=instance-state-name,Values=running,stopped" \
            --query "Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,IP:PrivateIpAddress}" \
            --output text --region "$REGION" 2>/dev/null)

        if [ -n "$INSTANCES" ]; then
            while IFS=$'\t' read -r INST_ID INST_NAME INST_IP; do
                [ -z "$INST_ID" ] && continue
                echo -e "      ${DIM}↳ Instanz: ${INST_NAME:-$INST_ID}  ($INST_IP)${NC}"
            done <<< "$INSTANCES"
        fi

        # Zugeordnete Subnetze (via SG-Name aus output.env)
        for ((n=1; n<=SUBNET_COUNT; n++)); do
            SG_VAR="SG_ID_$n"; SN_NAME_VAR="SN_NAME_$n"; SN_CIDR_VAR="SN_CIDR_$n"
            if [ "${!SG_VAR}" == "$SG_ID" ]; then
                echo -e "      ${DIM}↳ Subnetz:  ${!SN_NAME_VAR}  (${!SN_CIDR_VAR})${NC}"
            fi
        done

        # Inbound-Regeln
        RULES=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
            --query "SecurityGroups[0].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:IpRanges[0].CidrIp}" \
            --output text --region "$REGION" 2>/dev/null)

        if [ -n "$RULES" ]; then
            echo -e "      ${DIM}Inbound-Regeln:${NC}"
            while IFS=$'\t' read -r PROTO FROM TO CIDR; do
                [ -z "$PROTO" ] && continue
                if [ "$PROTO" == "-1" ]; then
                    echo -e "      ${DIM}  • Alle Protokolle  von  ${CIDR:-alle}${NC}"
                elif [ "$FROM" == "$TO" ]; then
                    echo -e "      ${DIM}  • $PROTO Port $FROM  von  ${CIDR:-alle}${NC}"
                else
                    echo -e "      ${DIM}  • $PROTO Port $FROM-$TO  von  ${CIDR:-alle}${NC}"
                fi
            done <<< "$RULES"
        else
            echo -e "      ${DIM}  (keine Inbound-Regeln)${NC}"
        fi

        echo ""
        ((i++))
    done <<< "$SG_LIST"
}

# ─── SG auswählen ─────────────────────────────────────────────────────────────
select_sg() {
    show_overview
    read -rp "Security Group auswählen [Nummer]: " SEL
    local IDX=$(( SEL - 1 ))
    if [ -z "${SG_IDS_LIST[$IDX]}" ]; then
        echo -e "${RED}Ungültige Auswahl.${NC}"
        return 1
    fi
    SELECTED_SG_ID="${SG_IDS_LIST[$IDX]}"
    SELECTED_SG_NAME="${SG_NAMES_LIST[$IDX]}"
    echo -e "  Gewählt: ${CYAN}$SELECTED_SG_NAME${NC}  ($SELECTED_SG_ID)"
    echo ""
}

# ─── Regel hinzufügen ─────────────────────────────────────────────────────────
add_rule() {
    select_sg || return

    echo -e "${BOLD}─── Neue Inbound-Regel ──────────────────────────────${NC}"
    echo -e "${DIM}  (entspricht AWS Konsole → Security Groups → Inbound rules)${NC}"
    echo ""

    # Typ-Auswahl wie in der AWS-Konsole
    echo -e "  Typ:"
    echo -e "    ${DIM}── Häufig verwendet ──────────────────${NC}"
    echo -e "    [1]  All traffic          (alle Protokolle + Ports)"
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
    echo -e "    [11] Custom TCP            eigener Port"
    echo -e "    [12] Custom UDP            eigener Port"
    echo ""
    read -rp "  Auswahl: " TYPE_SEL

    PROTO="" ; PORT="" ; ICMP_TYPE="" ; ICMP_CODE="" ; RULE_LABEL=""
    case "${TYPE_SEL}" in
        1)  PROTO="-1";                                    RULE_LABEL="All traffic" ;;
        2)  PROTO="icmp"; ICMP_TYPE="-1"; ICMP_CODE="-1"; RULE_LABEL="All ICMP" ;;
        3)  PROTO="icmp"
            echo ""
            echo -e "  ICMP-Typ:"
            echo -e "    [1] Echo Request  (Ping senden,  Type 8)"
            echo -e "    [2] Echo Reply    (Ping Antwort, Type 0)"
            echo -e "    [3] Destination Unreachable (Type 3)"
            echo -e "    [4] Time Exceeded (Traceroute, Type 11)"
            echo -e "    [5] Custom"
            read -rp "  Auswahl [1]: " ICMP_SEL
            case "${ICMP_SEL:-1}" in
                1) ICMP_TYPE="8";  ICMP_CODE="-1"; RULE_LABEL="ICMP Echo Request (Ping)" ;;
                2) ICMP_TYPE="0";  ICMP_CODE="-1"; RULE_LABEL="ICMP Echo Reply" ;;
                3) ICMP_TYPE="3";  ICMP_CODE="-1"; RULE_LABEL="ICMP Destination Unreachable" ;;
                4) ICMP_TYPE="11"; ICMP_CODE="-1"; RULE_LABEL="ICMP Time Exceeded" ;;
                5) read -rp "  ICMP Type (0-255): " ICMP_TYPE
                   read -rp "  ICMP Code [-1=alle]: " ICMP_CODE
                   ICMP_CODE="${ICMP_CODE:--1}"
                   RULE_LABEL="Custom ICMP Type $ICMP_TYPE Code $ICMP_CODE" ;;
            esac ;;
        4)  PROTO="tcp"; PORT="22";   RULE_LABEL="SSH (TCP 22)" ;;
        5)  PROTO="tcp"; PORT="80";   RULE_LABEL="HTTP (TCP 80)" ;;
        6)  PROTO="tcp"; PORT="443";  RULE_LABEL="HTTPS (TCP 443)" ;;
        7)  PROTO="tcp"; PORT="3389"; RULE_LABEL="RDP (TCP 3389)" ;;
        8)  PROTO="tcp"; PORT="3306"; RULE_LABEL="MySQL/Aurora (TCP 3306)" ;;
        9)  PROTO="tcp"; PORT="5432"; RULE_LABEL="PostgreSQL (TCP 5432)" ;;
        10) PROTO="tcp"; PORT="1433"; RULE_LABEL="MS SQL (TCP 1433)" ;;
        11) PROTO="tcp"
            read -rp "  Port: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                echo -e "${RED}Ungültiger Port.${NC}"; return
            fi
            RULE_LABEL="Custom TCP $PORT" ;;
        12) PROTO="udp"
            read -rp "  Port: " PORT
            if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                echo -e "${RED}Ungültiger Port.${NC}"; return
            fi
            RULE_LABEL="Custom UDP $PORT" ;;
        *)  echo -e "${RED}Ungültige Auswahl.${NC}"; return ;;
    esac

    # Quelle
    echo ""
    echo -e "  Quelle:"
    echo -e "    [1] Anywhere-IPv4  (0.0.0.0/0)"
    echo -e "    [2] My IP          (nur dein aktuelles Netz – VPC: $VPC_CIDR)"
    echo -e "    [3] Custom CIDR    (eigene Eingabe)"
    read -rp "  Auswahl [1]: " CIDR_SEL
    case "${CIDR_SEL:-1}" in
        2) CIDR="$VPC_CIDR" ;;
        3) read -rp "  CIDR: " CIDR ;;
        *) CIDR="0.0.0.0/0" ;;
    esac

    echo ""
    echo -e "  Neue Regel: ${CYAN}$RULE_LABEL${NC}  von  ${CYAN}$CIDR${NC}"
    read -rp "  Hinzufügen? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return

    # AWS CLI Aufruf je nach Protokoll
    if [ "$PROTO" == "-1" ]; then
        RESULT=$(aws ec2 authorize-security-group-ingress \
            --group-id "$SELECTED_SG_ID" --protocol -1 --cidr "$CIDR" \
            --region "$REGION" 2>&1)
    elif [ "$PROTO" == "icmp" ]; then
        RESULT=$(aws ec2 authorize-security-group-ingress \
            --group-id "$SELECTED_SG_ID" --protocol icmp \
            --port "$ICMP_TYPE" \
            --cidr "$CIDR" \
            --region "$REGION" 2>&1)
    else
        RESULT=$(aws ec2 authorize-security-group-ingress \
            --group-id "$SELECTED_SG_ID" --protocol "$PROTO" \
            --port "$PORT" --cidr "$CIDR" \
            --region "$REGION" 2>&1)
    fi

    if echo "$RESULT" | grep -q "InvalidPermission.Duplicate"; then
        echo -e "  ${YELLOW}Regel existiert bereits.${NC}"
    elif echo "$RESULT" | grep -q "error\|Error"; then
        echo -e "  ${RED}Fehler: $RESULT${NC}"
    else
        echo -e "  ${GREEN}✓ $RULE_LABEL hinzugefügt${NC}"
    fi
}

# ─── Regel entfernen ──────────────────────────────────────────────────────────
remove_rule() {
    select_sg || return

    echo -e "${BOLD}─── Bestehende Inbound-Regeln ───────────────────────${NC}"
    echo ""

    RULES_RAW=$(aws ec2 describe-security-groups --group-ids "$SELECTED_SG_ID" \
        --query "SecurityGroups[0].IpPermissions" \
        --output json --region "$REGION" 2>/dev/null)

    RULE_COUNT=$(echo "$RULES_RAW" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

    if [ -z "$RULE_COUNT" ] || [ "$RULE_COUNT" -eq 0 ]; then
        echo -e "  ${DIM}Keine Inbound-Regeln vorhanden.${NC}"
        return
    fi

    declare -a RULE_DISPLAY
    for ((r=0; r<RULE_COUNT; r++)); do
        PROTO=$(echo "$RULES_RAW" | python3 -c "import sys,json; d=json.load(sys.stdin)[$r]; print(d.get('IpProtocol',''))" 2>/dev/null)
        FROM=$(echo "$RULES_RAW" | python3 -c "import sys,json; d=json.load(sys.stdin)[$r]; print(d.get('FromPort',''))" 2>/dev/null)
        TO=$(echo "$RULES_RAW" | python3 -c "import sys,json; d=json.load(sys.stdin)[$r]; print(d.get('ToPort',''))" 2>/dev/null)
        CIDR=$(echo "$RULES_RAW" | python3 -c "import sys,json; d=json.load(sys.stdin)[$r]; ranges=d.get('IpRanges',[]); print(ranges[0]['CidrIp'] if ranges else 'alle')" 2>/dev/null)

        if [ "$PROTO" == "-1" ]; then
            DISPLAY="Alle Protokolle  von  $CIDR"
        elif [ "$FROM" == "$TO" ]; then
            DISPLAY="$PROTO Port $FROM  von  $CIDR"
        else
            DISPLAY="$PROTO Port $FROM-$TO  von  $CIDR"
        fi
        echo -e "  ${CYAN}[$((r+1))]${NC} $DISPLAY"
        RULE_DISPLAY[$r]="$DISPLAY"
    done

    echo ""
    read -rp "Welche Regel entfernen? [Nummer]: " RSEL
    RIDX=$(( RSEL - 1 ))

    if [ "$RIDX" -lt 0 ] || [ "$RIDX" -ge "$RULE_COUNT" ]; then
        echo -e "${RED}Ungültige Auswahl.${NC}"; return
    fi

    RULE_JSON=$(echo "$RULES_RAW" | python3 -c "import sys,json; print(json.dumps([json.load(sys.stdin)[$RIDX]]))" 2>/dev/null)

    echo -e "  Entferne: ${RED}${RULE_DISPLAY[$RIDX]}${NC}"
    read -rp "  Wirklich entfernen? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return

    RESULT=$(aws ec2 revoke-security-group-ingress \
        --group-id "$SELECTED_SG_ID" \
        --ip-permissions "$RULE_JSON" \
        --region "$REGION" 2>&1)

    if echo "$RESULT" | grep -q "error\|Error"; then
        echo -e "  ${RED}Fehler: $RESULT${NC}"
    else
        echo -e "  ${GREEN}✓ Regel entfernt${NC}"
    fi
}

# ─── Hauptmenü ────────────────────────────────────────────────────────────────
while true; do
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Security Groups verwalten               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
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
