#!/bin/bash

# AWS Academy Credentials aktualisieren
# Unterstuetzt beide Formate die AWS Academy anzeigt:
#   Format 1: aws_access_key_id=ASIA...
#   Format 2: export AWS_ACCESS_KEY_ID=ASIA...

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CRED_FILE="$HOME/.aws/credentials"

echo -e "${BOLD}=== AWS Academy Credentials aktualisieren ===${NC}"
echo ""
echo -e "${YELLOW}Schritte im AWS Academy Learner Lab:${NC}"
echo -e "  1. Klicke auf ${CYAN}AWS Details${NC}"
echo -e "  2. Klicke auf ${CYAN}Show${NC} neben 'AWS CLI'"
echo -e "  3. Kopiere den gesamten Block (Cmd+A, Cmd+C)"
echo ""
echo -e "Dann hier einfuegen und mit ${CYAN}ENTER + Ctrl+D${NC} bestaetigen:"
echo -e "${YELLOW}────────────────────────────────────────${NC}"

INPUT=$(cat)

echo -e "${YELLOW}────────────────────────────────────────${NC}"
echo ""

# ─── Werte aus beiden Formaten extrahieren ────────────────────────────────────
# Format 1: aws_access_key_id=...  oder  aws_access_key_id = ...
# Format 2: export AWS_ACCESS_KEY_ID=...

KEY_ID=$(echo "$INPUT" | grep -i "aws_access_key_id" | sed 's/^[^=]*=[ ]*//' | tr -d ' \r\n')
SECRET=$(echo "$INPUT" | grep -i "aws_secret_access_key" | sed 's/^[^=]*=[ ]*//' | tr -d ' \r\n')
TOKEN=$(echo "$INPUT" | grep -i "aws_session_token" | sed 's/^[^=]*=[ ]*//' | tr -d ' \r\n')

# ─── Validierung ──────────────────────────────────────────────────────────────
ERRORS=0
if [ -z "$KEY_ID" ]; then
    echo -e "  ${RED}✗ aws_access_key_id nicht gefunden${NC}"
    ERRORS=$((ERRORS+1))
fi
if [ -z "$SECRET" ]; then
    echo -e "  ${RED}✗ aws_secret_access_key nicht gefunden${NC}"
    ERRORS=$((ERRORS+1))
fi
if [ -z "$TOKEN" ]; then
    echo -e "  ${RED}✗ aws_session_token nicht gefunden${NC}"
    ERRORS=$((ERRORS+1))
fi

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo -e "${RED}Credentials konnten nicht gelesen werden.${NC}"
    echo -e "${YELLOW}Tipp: Gesamten Block aus AWS Academy kopieren (inkl. [default])${NC}"
    exit 1
fi

# ─── Backup der alten Credentials ────────────────────────────────────────────
if [ -f "$CRED_FILE" ]; then
    cp "$CRED_FILE" "${CRED_FILE}.bak"
fi

# ─── Credentials schreiben ────────────────────────────────────────────────────
mkdir -p "$HOME/.aws"
cat > "$CRED_FILE" <<EOF
[default]
aws_access_key_id=$KEY_ID
aws_secret_access_key=$SECRET
aws_session_token=$TOKEN
EOF

chmod 600 "$CRED_FILE"

# ─── Verifizieren ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Verbindung testen...${NC}"
IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1)

if echo "$IDENTITY" | grep -q "arn:aws"; then
    echo -e "  ${GREEN}✓ Credentials gueltig${NC}"
    echo -e "  ${CYAN}$IDENTITY${NC}"
    echo ""
    echo -e "${GREEN}Credentials erfolgreich aktualisiert!${NC}"
else
    echo -e "  ${RED}✗ Verbindungstest fehlgeschlagen: $IDENTITY${NC}"
    # Backup wiederherstellen
    [ -f "${CRED_FILE}.bak" ] && mv "${CRED_FILE}.bak" "$CRED_FILE"
    exit 1
fi
