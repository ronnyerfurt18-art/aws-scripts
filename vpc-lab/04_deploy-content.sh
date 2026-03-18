#!/bin/bash

# SCHRITT 4: Inhalt per SSH auf EC2 Instanzen deployen
# Schreibt index.html direkt auf die Instanz (Alternative zu User-Data)

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

echo -e "${BOLD}=== Schritt 4: Inhalt deployen ===${NC}"
echo ""

# PEM-Datei ermitteln
PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"
if [ ! -f "$PEM_FILE" ]; then
    echo -e "${YELLOW}PEM-Datei nicht gefunden unter: $PEM_FILE${NC}"
    read -rp "Pfad zur PEM-Datei: " PEM_FILE
    if [ ! -f "$PEM_FILE" ]; then
        echo -e "${RED}Fehler: PEM-Datei nicht gefunden.${NC}"
        exit 1
    fi
fi

echo -e "  Key: ${CYAN}$PEM_FILE${NC}"
echo ""

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_NAME_VAR="SN_NAME_$n"
    SN_TYPE_VAR="SN_TYPE_$n"
    INSTANCE_ID_VAR="INSTANCE_ID_$n"

    SN_NAME="${!SN_NAME_VAR}"
    SN_TYPE="${!SN_TYPE_VAR}"
    IID="${!INSTANCE_ID_VAR}"

    if [ "$SN_TYPE" != "public" ]; then
        echo -e "  ${YELLOW}ec2-${SN_NAME}${NC} ist Private – kein SSH von aussen moeglich, wird uebersprungen."
        echo ""
        continue
    fi

    PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" == "None" ]; then
        echo -e "  ${RED}ec2-${SN_NAME}: Keine Public IP verfuegbar.${NC}"
        continue
    fi

    echo -e "${YELLOW}Deploye auf ec2-${SN_NAME} ($PUBLIC_IP)...${NC}"

    # Instanz-Status pruefen
    STATUS=$(aws ec2 describe-instance-status --instance-ids "$IID" \
        --query "InstanceStatuses[0].InstanceStatus.Status" \
        --output text --region "$REGION" 2>/dev/null)

    if [ "$STATUS" != "ok" ]; then
        echo -e "  ${YELLOW}Instanz noch nicht bereit (Status: $STATUS).${NC}"
        echo -e "  Warte auf 'ok'..."
        aws ec2 wait instance-status-ok --instance-ids "$IID" --region "$REGION"
        echo -e "  ${GREEN}Instanz bereit.${NC}"
    fi

    # HTML-Inhalt abfragen
    echo ""
    read -rp "  Inhalt fuer index.html [Hello public]: " HTML_CONTENT
    HTML_CONTENT="${HTML_CONTENT:-Hello public}"

    # Per SSH deployen
    ssh -i "$PEM_FILE" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        ec2-user@"$PUBLIC_IP" \
        "sudo yum install -y httpd 2>/dev/null; sudo systemctl start httpd; sudo systemctl enable httpd; echo '<h1>${HTML_CONTENT}</h1>' | sudo tee /var/www/html/index.html > /dev/null"

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}Erfolgreich deployed!${NC}"
        echo -e "  URL: ${CYAN}http://$PUBLIC_IP${NC}"
        echo -e "  Inhalt: ${CYAN}$HTML_CONTENT${NC}"
    else
        echo -e "  ${RED}Fehler beim Deployment.${NC}"
        echo -e "  Manuell: ssh -i $PEM_FILE ec2-user@$PUBLIC_IP"
    fi
    echo ""
done
