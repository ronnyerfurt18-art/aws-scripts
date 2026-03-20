#!/bin/bash

# SCHRITT 8: index.html pro Instanz setzen oder anpassen
# Public: direkt per SSH
# Private: per Jump Host durch public Instanz

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_01="$SCRIPT_DIR/01_output.env"
EC2_OUTPUT="$SCRIPT_DIR/02_output.env"

if [ ! -f "$EC2_OUTPUT" ]; then
    echo -e "${RED}Fehler: 02_output.env nicht gefunden. Schritt 2 (EC2 Setup) muss vorher ausgefuehrt werden.${NC}"
    exit 1
fi

[ -f "$SCRIPT_DIR/config.env" ] && source "$SCRIPT_DIR/config.env"
[ -f "$OUTPUT_01" ] && source "$OUTPUT_01"
source "$EC2_OUTPUT"

echo -e "${BOLD}=== Schritt 8: index.html deployen ===${NC}"
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

SSH_OPTS="-i $PEM_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ─── IPs aller Instanzen abrufen + Jump Host ermitteln ───────────────────────
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

# ─── Uebersicht ───────────────────────────────────────────────────────────────
printf "\r\033[K"
echo -e "${BOLD}─── Instanzen ───────────────────────────────────────${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    case "${INST_TYPE[$n]}" in
        public)  T="${GREEN}public${NC}" ;;
        private) T="${RED}private${NC}" ;;
        *)       T="${YELLOW}isoliert${NC}" ;;
    esac
    PUB_DISPLAY="${INST_PUB[$n]:--}"
    if [ -n "${INST_PUB[$n]}" ]; then
        URL_DISPLAY="  ${CYAN}http://${INST_PUB[$n]}${NC}"
    else
        URL_DISPLAY="  ${DIM}(keine public IP)${NC}"
    fi
    echo -e "  [$n] ec2-${INST_NAME[$n]}  [$T]$URL_DISPLAY"
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

# ─── Deployment pro Instanz ───────────────────────────────────────────────────
echo ""
for N in "${SELECTED[@]}"; do
    SN_NAME="${INST_NAME[$N]}"
    SN_TYPE="${INST_TYPE[$N]}"
    PUB_IP="${INST_PUB[$N]}"
    PRIV_IP="${INST_PRIV[$N]}"

    if [ "$SN_TYPE" == "none" ]; then
        echo -e "  ${YELLOW}ec2-${SN_NAME}${NC} [Isoliert] – wird uebersprungen"
        echo ""
        continue
    fi

    if [ "$SN_TYPE" == "public" ] && { [ -z "$PUB_IP" ] || [ "$PUB_IP" == "None" ]; }; then
        echo -e "  ${RED}ec2-${SN_NAME}: Keine Public IP – Instanz noch nicht bereit.${NC}"
        echo ""
        continue
    fi

    if [ "$SN_TYPE" == "private" ] && { [ -z "$JUMP_IP" ] || [ "$JUMP_IP" == "None" ]; }; then
        echo -e "  ${RED}ec2-${SN_NAME}: Kein Jump Host verfuegbar (public Instanz fehlt).${NC}"
        echo ""
        continue
    fi

    echo -e "${BOLD}ec2-${SN_NAME}${NC}"
    if [ -n "$PUB_IP" ]; then
        echo -e "  URL: ${CYAN}http://$PUB_IP${NC}"
    fi
    read -rp "  Inhalt fuer index.html: " HTML_CONTENT

    REMOTE_CMD="echo '<h1>${HTML_CONTENT}</h1>' | sudo tee /var/www/html/index.html > /dev/null"

    if [ "$SN_TYPE" == "public" ]; then
        ssh $SSH_OPTS ec2-user@"$PUB_IP" "$REMOTE_CMD" 2>&1
    else
        ssh $SSH_OPTS \
            -o "ProxyCommand=ssh -i $PEM_FILE -o StrictHostKeyChecking=no -W %h:%p ec2-user@$JUMP_IP" \
            ec2-user@"$PRIV_IP" "$REMOTE_CMD" 2>&1
    fi

    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Deployed!${NC}"
        if [ -n "$PUB_IP" ]; then
            echo -e "  ${CYAN}http://$PUB_IP${NC}"
        fi
    else
        echo -e "  ${RED}Fehler beim Deployment.${NC}"
    fi
    echo ""
done

echo -e "${BOLD}=== Deployment abgeschlossen ===${NC}"
