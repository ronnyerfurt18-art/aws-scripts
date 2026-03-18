#!/bin/bash

# SCHRITT 7: httpd auf allen Instanzen installieren und index.html setzen
# Public Instanzen: direkt per SSH
# Private/None Instanzen: per SSH Jump Host durch die public Instanz

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_01="$SCRIPT_DIR/01_output.env"
OUTPUT_02="$SCRIPT_DIR/02_output.env"

[ ! -f "$OUTPUT_01" ] && echo -e "${RED}Fehler: 01_output.env nicht gefunden.${NC}" && exit 1
[ ! -f "$OUTPUT_02" ] && echo -e "${RED}Fehler: 02_output.env nicht gefunden.${NC}" && exit 1

source "$OUTPUT_01"
source "$OUTPUT_02"

echo -e "${BOLD}=== Schritt 7: httpd Installation ===${NC}"
echo ""

# ─── PEM-Datei ermitteln ──────────────────────────────────────────────────────
PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"
if [ ! -f "$PEM_FILE" ]; then
    echo -e "${YELLOW}PEM-Datei nicht gefunden unter: $PEM_FILE${NC}"
    read -rp "Pfad zur PEM-Datei: " PEM_FILE
    [ ! -f "$PEM_FILE" ] && echo -e "${RED}Fehler: PEM-Datei nicht gefunden.${NC}" && exit 1
fi
echo -e "  Key: ${CYAN}$PEM_FILE${NC}"

SSH_OPTS="-i $PEM_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# ─── Public Instanz als Jump Host ermitteln ───────────────────────────────────
JUMP_IP=""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_TYPE_VAR="SN_TYPE_$n"
    IID_VAR="INSTANCE_ID_$n"
    if [ "${!SN_TYPE_VAR}" == "public" ]; then
        JUMP_IP=$(aws ec2 describe-instances --instance-ids "${!IID_VAR}" \
            --query "Reservations[0].Instances[0].PublicIpAddress" \
            --output text --region "$REGION" 2>/dev/null)
        break
    fi
done

if [ -z "$JUMP_IP" ] || [ "$JUMP_IP" == "None" ]; then
    echo -e "${RED}Kein public Subnetz mit erreichbarer Instanz gefunden.${NC}"
    echo -e "${RED}Mindestens eine Instanz muss public sein (als Jump Host).${NC}"
    exit 1
fi
echo -e "  Jump Host: ${CYAN}$JUMP_IP${NC}"
echo ""

# ─── Hilfsfunktion: httpd installieren und index.html setzen ─────────────────
install_httpd() {
    local SSH_CMD="$1"
    local CONTENT="$2"

    $SSH_CMD "
        if ! systemctl is-active --quiet httpd 2>/dev/null; then
            sudo yum install -y httpd > /dev/null 2>&1
            sudo systemctl enable httpd > /dev/null 2>&1
            sudo systemctl start httpd
        fi
        echo '<h1>$CONTENT</h1>' | sudo tee /var/www/html/index.html > /dev/null
        curl -s http://localhost | grep -o '<h1>.*</h1>'
    "
}

# ─── Alle Instanzen durchgehen ────────────────────────────────────────────────
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_NAME_VAR="SN_NAME_$n"
    SN_TYPE_VAR="SN_TYPE_$n"
    IID_VAR="INSTANCE_ID_$n"

    SN_NAME="${!SN_NAME_VAR}"
    SN_TYPE="${!SN_TYPE_VAR}"
    IID="${!IID_VAR}"

    if [ "$SN_TYPE" == "none" ]; then
        echo -e "  ${YELLOW}ec2-${SN_NAME}${NC} [Isoliert] – wird uebersprungen (keine SG-Regeln)"
        echo ""
        continue
    fi

    PRIV_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text --region "$REGION" 2>/dev/null)

    # HTTP-Text abfragen
    if [ "$SN_TYPE" == "public" ]; then
        DEFAULT_TEXT="Hello, ich bin eine oeffentliche Instanz"
    else
        DEFAULT_TEXT="Hallo, ich bin eine private Instanz"
    fi
    read -rp "  Inhalt index.html fuer ec2-${SN_NAME} [$DEFAULT_TEXT]: " CONTENT
    CONTENT="${CONTENT:-$DEFAULT_TEXT}"

    echo -e "  ${YELLOW}Installiere httpd auf ec2-${SN_NAME} ($PRIV_IP)...${NC}"

    if [ "$SN_TYPE" == "public" ]; then
        # Direkt erreichbar
        PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
            --query "Reservations[0].Instances[0].PublicIpAddress" \
            --output text --region "$REGION" 2>/dev/null)
        RESULT=$(install_httpd "ssh $SSH_OPTS ec2-user@$PUBLIC_IP" "$CONTENT" 2>&1)
    else
        # Ueber Jump Host (ProxyJump)
        RESULT=$(install_httpd "ssh $SSH_OPTS -J ec2-user@$JUMP_IP ec2-user@$PRIV_IP" "$CONTENT" 2>&1)
    fi

    if echo "$RESULT" | grep -q "<h1>"; then
        echo -e "  ${GREEN}✓ ec2-${SN_NAME}${NC}: httpd laeuft, Antwort: $RESULT"
    else
        echo -e "  ${RED}✗ ec2-${SN_NAME}${NC}: Fehler – $RESULT"
    fi
    echo ""
done

echo -e "${BOLD}=== Installation abgeschlossen ===${NC}"
echo ""
echo -e "Testen mit: ${CYAN}./06_demo-screenshot.sh${NC}"
