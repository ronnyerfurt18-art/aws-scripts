#!/bin/bash

# SCHRITT 7: httpd auf ausgewaehlten Instanzen installieren
# Public Instanzen: direkt per SSH
# Private/None Instanzen: per SSH Jump Host durch die public Instanz

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_01="$SCRIPT_DIR/01_output.env"
OUTPUT_02="$SCRIPT_DIR/02_output.env"

[ ! -f "$OUTPUT_01" ] && echo -e "${RED}Fehler: 01_output.env nicht gefunden. Schritt 5 (VPC Setup) muss vorher ausgefuehrt werden.${NC}" && exit 1
[ ! -f "$OUTPUT_02" ] && echo -e "${RED}Fehler: 02_output.env nicht gefunden. Schritt 6 (EC2 Setup) muss vorher ausgefuehrt werden.${NC}" && exit 1

[ -f "$SCRIPT_DIR/config.env" ] && source "$SCRIPT_DIR/config.env"
source "$OUTPUT_01"
source "$OUTPUT_02"

if [ -z "$SUBNET_COUNT" ] || [ "$SUBNET_COUNT" -eq 0 ] 2>/dev/null; then
    echo -e "${RED}Fehler: Kein aktives EC2-Setup gefunden.${NC}"
    echo -e "${YELLOW}Bitte zuerst Schritt 5 (VPC Setup) und Schritt 6 (EC2 Instanzen) ausfuehren.${NC}"
    exit 1
fi

echo -e "${BOLD}=== Schritt 7: httpd Installation ===${NC}"
echo ""

# ─── PEM-Datei ermitteln ──────────────────────────────────────────────────────
PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"
if [ ! -f "$PEM_FILE" ]; then
    mapfile -t PEM_FILES < <(ls "$SCRIPT_DIR"/*.pem 2>/dev/null)
    if [ ${#PEM_FILES[@]} -eq 1 ]; then
        PEM_FILE="${PEM_FILES[0]}"
        echo -e "  ${YELLOW}PEM automatisch gefunden: ${CYAN}${PEM_FILE##*/}${NC}"
    elif [ ${#PEM_FILES[@]} -gt 1 ]; then
        echo -e "${YELLOW}Mehrere PEM-Dateien gefunden:${NC}"
        for i in "${!PEM_FILES[@]}"; do echo -e "  [$((i+1))] ${PEM_FILES[$i]##*/}"; done
        read -rp "Auswahl [1]: " PEM_SEL
        PEM_FILE="${PEM_FILES[$((${PEM_SEL:-1}-1))]}"
    else
        echo -e "${YELLOW}Keine PEM-Datei gefunden in: $SCRIPT_DIR${NC}"
        read -rp "Pfad zur PEM-Datei: " PEM_FILE
        [ ! -f "$PEM_FILE" ] && echo -e "${RED}Fehler: PEM-Datei nicht gefunden.${NC}" && exit 1
    fi
    DETECTED_KEY="${PEM_FILE##*/}"; DETECTED_KEY="${DETECTED_KEY%.pem}"
    if [ -n "$DETECTED_KEY" ]; then
        KEY_NAME="$DETECTED_KEY"
        if grep -q "^KEY_NAME=" "$SCRIPT_DIR/config.env" 2>/dev/null; then
            sed -i '' "s/^KEY_NAME=.*/KEY_NAME=$DETECTED_KEY/" "$SCRIPT_DIR/config.env"
        else
            echo "KEY_NAME=$DETECTED_KEY" >> "$SCRIPT_DIR/config.env"
        fi
    fi
fi
echo -e "  Key: ${CYAN}$PEM_FILE${NC}"

SSH_OPTS="-i $PEM_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ─── IPs aller Instanzen abrufen + Jump Host ermitteln ───────────────────────
echo ""
echo -e "${DIM}Lade Instanz-IPs...${NC}"

JUMP_IP=""
declare -a INST_PUB INST_PRIV INST_NAME INST_TYPE

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_NAME_VAR="SN_NAME_$n"; SN_TYPE_VAR="SN_TYPE_$n"; IID_VAR="INSTANCE_ID_$n"
    SN_NAME="${!SN_NAME_VAR}"; SN_TYPE="${!SN_TYPE_VAR}"; IID="${!IID_VAR}"

    RESULT=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]" \
        --output text --region "$REGION" 2>/dev/null)
    PUB=$(echo "$RESULT" | awk '{print $1}'); [ "$PUB" == "None" ] && PUB=""
    PRIV=$(echo "$RESULT" | awk '{print $2}'); [ "$PRIV" == "None" ] && PRIV=""

    INST_NAME[$n]="$SN_NAME"
    INST_TYPE[$n]="$SN_TYPE"
    INST_PUB[$n]="$PUB"
    INST_PRIV[$n]="$PRIV"

    [ "$SN_TYPE" == "public" ] && [ -n "$PUB" ] && [ -z "$JUMP_IP" ] && JUMP_IP="$PUB"
done

# ─── Instanzauswahl ───────────────────────────────────────────────────────────
printf "\r\033[K"
echo -e "${BOLD}─── Instanzen ───────────────────────────────────────${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    case "${INST_TYPE[$n]}" in
        public)  T="${GREEN}public${NC}" ;;
        private) T="${RED}private${NC}" ;;
        *)       T="${YELLOW}isoliert${NC}" ;;
    esac
    PUB_DISPLAY="${INST_PUB[$n]:--}"
    PRIV_DISPLAY="${INST_PRIV[$n]:--}"
    echo -e "  [$n] ec2-${INST_NAME[$n]}  [$T]  pub: ${CYAN}$PUB_DISPLAY${NC}  priv: ${CYAN}$PRIV_DISPLAY${NC}"
done
echo ""
echo -e "  ${DIM}Nummern kommagetrennt oder [A] fuer alle${NC}"
read -rp "Auswahl: " RAW_SEL

if [[ "$RAW_SEL" =~ ^[Aa]$ ]]; then
    SELECTED=()
    for ((n=1; n<=SUBNET_COUNT; n++)); do SELECTED+=("$n"); done
else
    IFS=',' read -ra PARTS <<< "$RAW_SEL"
    SELECTED=()
    for P in "${PARTS[@]}"; do
        P=$(echo "$P" | tr -d ' ')
        [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le "$SUBNET_COUNT" ] && SELECTED+=("$P")
    done
fi

if [ ${#SELECTED[@]} -eq 0 ]; then
    echo -e "${RED}Keine gueltige Auswahl.${NC}"; exit 1
fi

# ─── Jump Host pruefen falls private Instanzen dabei ─────────────────────────
NEEDS_JUMP=false
for N in "${SELECTED[@]}"; do
    [ "${INST_TYPE[$N]}" != "public" ] && NEEDS_JUMP=true && break
done

if $NEEDS_JUMP && { [ -z "$JUMP_IP" ] || [ "$JUMP_IP" == "None" ]; }; then
    echo -e "${RED}Fehler: Private Instanz gewaehlt, aber kein erreichbarer Jump Host (public Instanz).${NC}"
    exit 1
fi

# ─── httpd installieren ───────────────────────────────────────────────────────
echo ""
for N in "${SELECTED[@]}"; do
    SN_NAME="${INST_NAME[$N]}"
    SN_TYPE="${INST_TYPE[$N]}"
    PUB_IP="${INST_PUB[$N]}"
    PRIV_IP="${INST_PRIV[$N]}"

    if [ "$SN_TYPE" == "none" ]; then
        echo -e "  ${YELLOW}ec2-${SN_NAME}${NC} [Isoliert] – wird uebersprungen (keine SG-Regeln)"
        echo ""
        continue
    fi

    echo -e "  ${YELLOW}Installiere httpd auf ec2-${SN_NAME}...${NC}"

    if [ "$SN_TYPE" == "public" ]; then
        RESULT=$(ssh $SSH_OPTS ec2-user@"$PUB_IP" "
            if ! systemctl is-active --quiet httpd 2>/dev/null; then
                sudo yum install -y httpd > /dev/null 2>&1
                sudo systemctl enable httpd > /dev/null 2>&1
                sudo systemctl start httpd
            fi
            systemctl is-active httpd
        " 2>&1)
    else
        RESULT=$(ssh $SSH_OPTS \
            -o "ProxyCommand=ssh -i $PEM_FILE -o StrictHostKeyChecking=no -W %h:%p ec2-user@$JUMP_IP" \
            ec2-user@"$PRIV_IP" "
            if ! systemctl is-active --quiet httpd 2>/dev/null; then
                sudo yum install -y httpd > /dev/null 2>&1
                sudo systemctl enable httpd > /dev/null 2>&1
                sudo systemctl start httpd
            fi
            systemctl is-active httpd
        " 2>&1)
    fi

    if echo "$RESULT" | grep -q "active"; then
        echo -e "  ${GREEN}✓ ec2-${SN_NAME}${NC}: httpd laeuft"
    else
        echo -e "  ${RED}✗ ec2-${SN_NAME}${NC}: Fehler – $RESULT"
    fi
    echo ""
done

echo -e "${BOLD}=== Installation abgeschlossen ===${NC}"
echo -e "${DIM}Inhalt (index.html) setzen: Menue Punkt 8${NC}"
