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
    echo -e "${RED}Fehler: 02_output.env nicht gefunden.${NC}"
    echo -e "Bitte zuerst ./02_ec2-setup.sh ausfuehren."
    exit 1
fi

source "$EC2_OUTPUT"

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

    echo -e "  ec2-${SN_NAME} $LABEL  Status: $STATE"
    echo -e "    Private IP: ${CYAN}$PRIV_IP${NC}"
    if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
        echo -e "    Public IP:  ${CYAN}$PUBLIC_IP${NC}"
        echo -e "    URL:        ${CYAN}http://$PUBLIC_IP${NC}"
        echo -e "    SSH:        ${CYAN}ssh -i \$PEM ec2-user@$PUBLIC_IP${NC}"
    else
        echo -e "    ${YELLOW}Noch keine Public IP – Instanz startet noch.${NC}"
    fi
    echo ""
done
