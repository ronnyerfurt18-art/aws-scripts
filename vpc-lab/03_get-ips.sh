#!/bin/bash

# SCHRITT 3: Public IPs der EC2 Instanzen abrufen

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EC2_OUTPUT="$SCRIPT_DIR/02_output.env"

if [ ! -f "$EC2_OUTPUT" ]; then
    echo -e "${RED}Fehler: 02_output.env nicht gefunden. Schritt 2 (EC2 Setup) muss vorher ausgefuehrt werden.${NC}"
    exit 1
fi

[ -f "$SCRIPT_DIR/config.env" ] && source "$SCRIPT_DIR/config.env"
source "$EC2_OUTPUT"

# PEM-Datei ermitteln
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
    fi
    # Erkannten KEY_NAME in config.env speichern fuer folgende Skripte
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

echo -e "${BOLD}=== Schritt 3: Public IPs abrufen ===${NC}"
echo ""

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_NAME_VAR="SN_NAME_$n"
    SN_TYPE_VAR="SN_TYPE_$n"
    INSTANCE_ID_VAR="INSTANCE_ID_$n"

    SN_NAME="${!SN_NAME_VAR}"
    SN_TYPE="${!SN_TYPE_VAR}"
    IID="${!INSTANCE_ID_VAR}"

    STATE=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].State.Name" \
        --output text --region "$REGION" 2>/dev/null)

    PRIV_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text --region "$REGION" 2>/dev/null)
    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text --region "$REGION" 2>/dev/null)

    case "$SN_TYPE" in
        public)  LABEL="${GREEN}[Public]${NC}" ;;
        private) LABEL="${RED}[Private – SG]${NC}" ;;
        none)    LABEL="${YELLOW}[Isoliert – SG]${NC}" ;;
        *)       LABEL="[$SN_TYPE]" ;;
    esac

    if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
        echo -e "  ${BOLD}$LABEL${NC}  ec2-${SN_NAME}  ${CYAN}http://$PUBLIC_IP${NC}"
    else
        echo -e "  ${BOLD}$LABEL${NC}  ec2-${SN_NAME}  ${YELLOW}(noch keine Public IP – Instanz startet noch)${NC}"
    fi
    echo -e "    Status:     $STATE"
    echo -e "    Private IP: ${CYAN}$PRIV_IP${NC}"
    if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
        echo -e "    Public IP:  ${CYAN}$PUBLIC_IP${NC}"
        echo -e "    SSH:        ${CYAN}ssh -i $PEM_FILE ec2-user@$PUBLIC_IP${NC}"
    fi
    echo ""
done
