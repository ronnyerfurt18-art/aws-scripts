#!/bin/bash

# SCHRITT 6: Klausur-Demo – Zugriffstests fuer Screenshots
# Zeigt: Private Instanz von aussen NICHT erreichbar, von innen schon

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

[ -f "$SCRIPT_DIR/config.env" ] && source "$SCRIPT_DIR/config.env"
source "$OUTPUT_01"
source "$OUTPUT_02"

echo -e "${BOLD}=== Schritt 6: Klausur Demo ===${NC}"
echo ""

# ─── IPs ermitteln ────────────────────────────────────────────────────────────
PUBLIC_IP=""
PRIVATE_IP=""
PUBLIC_IID=""
PRIVATE_IID=""
PUBLIC_NAME=""
PRIVATE_NAME=""

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_TYPE_VAR="SN_TYPE_$n"
    IID_VAR="INSTANCE_ID_$n"
    SN_NAME_VAR="SN_NAME_$n"
    SN_TYPE="${!SN_TYPE_VAR}"
    IID="${!IID_VAR}"
    SN_NAME="${!SN_NAME_VAR}"

    if [ "$SN_TYPE" == "public" ]; then
        PUBLIC_IID="$IID"
        PUBLIC_NAME="$SN_NAME"
        PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
            --query "Reservations[0].Instances[0].PublicIpAddress" \
            --output text --region "$REGION" 2>/dev/null)
    else
        PRIVATE_IID="$IID"
        PRIVATE_NAME="$SN_NAME"
        PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
            --query "Reservations[0].Instances[0].PrivateIpAddress" \
            --output text --region "$REGION" 2>/dev/null)
    fi
done

echo -e "  Public  (ec2-$PUBLIC_NAME):  ${CYAN}$PUBLIC_IP${NC}"
echo -e "  Private (ec2-$PRIVATE_NAME): ${CYAN}$PRIVATE_IP${NC}  (nur intern)"
echo ""

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
    else
        echo -e "${YELLOW}Keine PEM-Datei gefunden in: $SCRIPT_DIR${NC}"
        read -rp "Pfad zur PEM-Datei: " PEM_FILE
        [ ! -f "$PEM_FILE" ] && echo -e "${RED}Fehler: PEM-Datei nicht gefunden.${NC}" && exit 1
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

# ─── Test 1: Zugriff von AUSSEN auf private Instanz (muss scheitern) ──────────
echo -e "${BOLD}━━━ TEST 1: Zugriff von AUSSEN auf private Instanz ━━━${NC}"
echo -e "${YELLOW}Erwartet: TIMEOUT / Verbindung schlaegt fehl${NC}"
echo ""
echo -e "  \$ curl --max-time 5 http://$PRIVATE_IP"
echo ""
RESULT=$(curl --max-time 5 -s "http://$PRIVATE_IP" 2>&1)
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo -e "  ${GREEN}[KORREKT] Verbindung verweigert / Timeout (Exit: $EXIT_CODE)${NC}"
    echo -e "  ${GREEN}Die private Instanz ist von aussen NICHT erreichbar.${NC}"
else
    echo -e "  ${RED}[UNERWARTET] Verbindung hat geklappt: $RESULT${NC}"
fi
echo ""

# ─── Test 2: Zugriff von AUSSEN auf public Instanz (soll klappen) ─────────────
echo -e "${BOLD}━━━ TEST 2: Zugriff von AUSSEN auf public Instanz ━━━${NC}"
echo -e "${YELLOW}Erwartet: HTTP-Antwort${NC}"
echo ""
echo -e "  \$ curl http://$PUBLIC_IP"
echo ""
RESULT=$(curl --max-time 10 -s "http://$PUBLIC_IP" 2>&1)
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}[KORREKT] Antwort erhalten:${NC}"
    echo -e "  $RESULT"
else
    echo -e "  ${YELLOW}[FEHLER] Keine Antwort – Instanz noch nicht bereit?${NC}"
fi
echo ""

# ─── Test 3: SSH + curl von Public auf Private ────────────────────────────────
echo -e "${BOLD}━━━ TEST 3: Zugriff von INNEN (via Public-Instanz als Jump Host) ━━━${NC}"
echo -e "${YELLOW}Erwartet: HTTP-Antwort der privaten Instanz${NC}"
echo ""
echo -e "  [automatisch] SSH via Public-Instanz → curl auf Private-Instanz"
echo -e "  \$ ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP \"curl -s http://$PRIVATE_IP\""
echo ""

RESULT=$(ssh -i "$PEM_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    ec2-user@"$PUBLIC_IP" \
    "curl -s --max-time 10 http://$PRIVATE_IP" 2>&1)

if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}[KORREKT] Antwort der privaten Instanz:${NC}"
    echo -e "  $RESULT"
else
    echo -e "  ${YELLOW}[FEHLER] Zugriff nicht moeglich: $RESULT${NC}"
    echo -e "  ${YELLOW}Tipp: Instanz noch nicht bereit oder SSH in Private-SG fehlt.${NC}"
fi
echo ""
echo -e "${BOLD}Zum Nachvollziehen:${NC}"
echo -e "  ${CYAN}ssh -i $PEM_FILE ec2-user@$PUBLIC_IP${NC}"
echo -e "  Dann in der Public-Instanz:"
echo -e "  ${CYAN}curl http://$PRIVATE_IP${NC}"
echo ""

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo -e "${BOLD}━━━ Zusammenfassung fuer die Klausur ━━━${NC}"
echo ""
echo -e "  ${GREEN}✓ Private Instanz von aussen NICHT erreichbar${NC}"
echo -e "  ${GREEN}✓ Zugriff von innerhalb des VPC moeglich${NC}"
echo ""
echo -e "${BOLD}SSH-Befehle fuer manuelle Verbindung:${NC}"
echo -e "  ${CYAN}ssh -i $PEM_FILE ec2-user@$PUBLIC_IP${NC}"
echo -e "  Dann in der Public-Instanz:"
echo -e "  ${CYAN}curl http://$PRIVATE_IP${NC}"
echo -e "  ${CYAN}ssh -i ~/.ssh/${KEY_NAME}.pem ec2-user@$PRIVATE_IP${NC}"
