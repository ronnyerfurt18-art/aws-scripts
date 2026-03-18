#!/bin/bash

# SCHRITT 0: Key Pair erstellen oder vorhandenes auswaehlen
# Speichert .pem lokal und traegt KEY_NAME in config.env ein

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.env"

[ -f "$CONFIG" ] && source "$CONFIG"
[ -z "$REGION" ] && REGION="us-east-1"

clear
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           Key Pair verwalten                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Region: ${CYAN}$REGION${NC}"
echo ""

# ─── Vorhandene Key Pairs anzeigen ───────────────────────────────────────────
echo -e "${BOLD}─── Key Pairs in AWS ($REGION) ──────────────────────${NC}"

KP_RAW=$(aws ec2 describe-key-pairs \
    --query "KeyPairs[].KeyName" \
    --output text --region "$REGION" 2>/dev/null | tr '\t' '\n' | grep -v '^$')

declare -a KP_ARR
i=1

if [ -n "$KP_RAW" ]; then
    while IFS= read -r kp; do
        [ -z "$kp" ] && continue
        PEM_LABEL=""
        [ -f "$SCRIPT_DIR/${kp}.pem" ] && PEM_LABEL="${GREEN} ✓ .pem lokal vorhanden${NC}"
        ACTIVE_LABEL=""
        [ "$kp" == "$KEY_NAME" ] && ACTIVE_LABEL="${CYAN} [aktiv]${NC}"
        echo -e "  [${CYAN}$i${NC}] $kp$PEM_LABEL$ACTIVE_LABEL"
        KP_ARR[$i]="$kp"
        ((i++))
    done <<< "$KP_RAW"
else
    echo -e "  ${DIM}Keine Key Pairs gefunden.${NC}"
fi

echo ""
echo -e "  [${CYAN}n${NC}] Neues Key Pair erstellen"
echo -e "  [${CYAN}0${NC}] Zurueck"
echo ""

read -rp "  Auswahl (Nummer oder 'n'): " SEL
[ "$SEL" == "0" ] && exit 0

# ─── Vorhandenes auswaehlen ───────────────────────────────────────────────────
if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -lt "$i" ]; then
    KEY_NAME="${KP_ARR[$SEL]}"
    PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"

    if [ ! -f "$PEM_FILE" ]; then
        echo ""
        echo -e "  ${YELLOW}⚠  .pem-Datei nicht lokal vorhanden.${NC}"
        echo -e "  ${DIM}Der private Schluessel kann nicht erneut aus AWS heruntergeladen werden.${NC}"
        echo -e "  ${DIM}Falls die Datei woanders liegt, bitte hierhin kopieren:${NC}"
        echo -e "  ${CYAN}  $PEM_FILE${NC}"
    else
        echo -e "  ${GREEN}✓ .pem vorhanden: $PEM_FILE${NC}"
    fi

    # config.env aktualisieren
    if grep -q "^KEY_NAME=" "$CONFIG" 2>/dev/null; then
        sed -i '' "s/^KEY_NAME=.*/KEY_NAME=$KEY_NAME/" "$CONFIG"
    else
        echo "KEY_NAME=$KEY_NAME" >> "$CONFIG"
    fi
    echo -e "  ${GREEN}✓ '$KEY_NAME' als aktiver Key gesetzt.${NC}"
    exit 0
fi

# ─── Neues Key Pair erstellen ─────────────────────────────────────────────────
[ "$SEL" != "n" ] && [ "$SEL" != "N" ] && echo -e "${RED}Ungueltige Auswahl.${NC}" && exit 1

echo ""
echo -e "${BOLD}─── Neues Key Pair erstellen ────────────────────────${NC}"
read -rp "  Name fuer Key Pair: " KEY_NAME
[ -z "$KEY_NAME" ] && echo -e "${RED}Kein Name angegeben.${NC}" && exit 1

PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"

# Schon vorhanden?
EXISTING=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" \
    --query "KeyPairs[0].KeyName" --output text --region "$REGION" 2>/dev/null)

if [ "$EXISTING" == "$KEY_NAME" ]; then
    echo -e "  ${YELLOW}Key Pair '$KEY_NAME' existiert bereits in AWS.${NC}"
    if [ -f "$PEM_FILE" ]; then
        echo -e "  ${GREEN}✓ .pem bereits vorhanden – setze als aktiv.${NC}"
    else
        echo -e "  ${RED}⚠  .pem fehlt lokal. Alten Key loeschen und neu erstellen?${NC}"
        read -rp "  Loeschen + neu erstellen? [j/N]: " CONFIRM
        [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && exit 0
        aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION"
        echo -e "  ${GREEN}✓ Alter Key geloescht.${NC}"
        goto_create=true
    fi
else
    goto_create=true
fi

if [ "$goto_create" == "true" ]; then
    echo ""
    echo -e "${YELLOW}Erstelle Key Pair '$KEY_NAME' in $REGION...${NC}"
    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query "KeyMaterial" \
        --output text \
        --region "$REGION" > "$PEM_FILE"

    if [ $? -ne 0 ] || [ ! -s "$PEM_FILE" ]; then
        echo -e "${RED}Fehler beim Erstellen.${NC}"
        rm -f "$PEM_FILE"
        exit 1
    fi
    chmod 400 "$PEM_FILE"
    echo -e "${GREEN}✓ Key Pair erstellt + gespeichert.${NC}"
fi

# config.env aktualisieren
if grep -q "^KEY_NAME=" "$CONFIG" 2>/dev/null; then
    sed -i '' "s/^KEY_NAME=.*/KEY_NAME=$KEY_NAME/" "$CONFIG"
else
    echo "KEY_NAME=$KEY_NAME" >> "$CONFIG"
fi

echo ""
echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────────${NC}"
echo -e "  Key-Name:  ${CYAN}$KEY_NAME${NC}"
echo -e "  PEM-Datei: ${CYAN}$PEM_FILE${NC}"
echo -e "  Region:    ${CYAN}$REGION${NC}"
echo ""
echo -e "  ${DIM}SSH-Befehl:${NC}"
echo -e "  ${CYAN}ssh -i $PEM_FILE ec2-user@<PUBLIC_IP>${NC}"
