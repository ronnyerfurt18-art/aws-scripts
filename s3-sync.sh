#!/bin/bash

# S3 Sync – Lokalen Ordner mit S3 Bucket verbinden
# Erstellt Bucket, setzt public Policy, synchronisiert Dateien

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== S3 Sync – Lokaler Ordner → AWS S3 ===${NC}"
echo ""

# ─── Parameter ────────────────────────────────────────────────────────────────
read -rp "AWS Region             [us-east-1]:  " REGION
REGION="${REGION:-us-east-1}"

read -rp "Bucket-Name            [dhge-bodevi23]: " BUCKET
BUCKET="${BUCKET:-dhge-bodevi23}"

read -rp "Lokaler Ordner-Pfad:   " LOCAL_DIR
if [ -z "$LOCAL_DIR" ]; then
    echo -e "${RED}Fehler: Kein Pfad angegeben.${NC}"
    exit 1
fi

# ~ aufloesen
LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"

if [ ! -d "$LOCAL_DIR" ]; then
    echo -e "${RED}Fehler: Ordner '$LOCAL_DIR' nicht gefunden.${NC}"
    exit 1
fi

FILE_COUNT=$(find "$LOCAL_DIR" -type f | wc -l | tr -d ' ')
echo ""
echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────${NC}"
echo -e "  Region:        ${CYAN}$REGION${NC}"
echo -e "  Bucket:        ${CYAN}s3://$BUCKET${NC}"
echo -e "  Lokaler Pfad:  ${CYAN}$LOCAL_DIR${NC}  ($FILE_COUNT Dateien)"
echo -e "  Public URL:    ${CYAN}https://$BUCKET.s3.amazonaws.com/${NC}"
echo ""
read -rp "Setup starten? [j/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0
echo ""

# ─── 1. Bucket erstellen ──────────────────────────────────────────────────────
echo -e "${YELLOW}[1/4] Bucket erstellen...${NC}"

if [ "$REGION" == "us-east-1" ]; then
    RESULT=$(aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION" 2>&1)
else
    RESULT=$(aws s3api create-bucket \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" 2>&1)
fi

if echo "$RESULT" | grep -q "BucketAlreadyOwnedByYou\|already owned"; then
    echo -e "  ${YELLOW}Bucket existiert bereits – wird weiterverwendet.${NC}"
elif echo "$RESULT" | grep -q "error\|Error"; then
    echo -e "  ${RED}Fehler: $RESULT${NC}"
    exit 1
else
    echo -e "  ${GREEN}✓ Bucket erstellt:${NC} s3://$BUCKET"
fi

# ─── 2. Public Access Block deaktivieren ──────────────────────────────────────
echo -e "${YELLOW}[2/4] Oeffentlichen Zugriff erlauben...${NC}"
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
    --region "$REGION" 2>&1

echo -e "  ${GREEN}✓ Block Public Access deaktiviert${NC}"

# ─── 3. Bucket Policy setzen ──────────────────────────────────────────────────
echo -e "${YELLOW}[3/4] Bucket Policy setzen (public read)...${NC}"

POLICY=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::${BUCKET}/*"
        }
    ]
}
EOF
)

RESULT=$(aws s3api put-bucket-policy \
    --bucket "$BUCKET" \
    --policy "$POLICY" \
    --region "$REGION" 2>&1)

if echo "$RESULT" | grep -q "error\|Error"; then
    echo -e "  ${RED}Fehler beim Setzen der Policy: $RESULT${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓ Bucket Policy gesetzt (s3:GetObject fuer alle)${NC}"

# ─── 4. Dateien synchronisieren ───────────────────────────────────────────────
echo -e "${YELLOW}[4/4] Dateien synchronisieren...${NC}"
echo -e "  ${CYAN}$LOCAL_DIR${NC} → ${CYAN}s3://$BUCKET${NC}"
echo ""

aws s3 sync "$LOCAL_DIR" "s3://$BUCKET" \
    --region "$REGION" \
    --exclude ".DS_Store" \
    --exclude "*.pem" \
    --exclude "*.key"

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${BOLD}=== Sync abgeschlossen ===${NC}"
    echo ""
    echo -e "  ${GREEN}✓ Bucket:${NC}     s3://$BUCKET"
    echo -e "  ${GREEN}✓ Public URL:${NC} ${CYAN}https://$BUCKET.s3.amazonaws.com/${NC}"
    echo ""
    echo -e "${YELLOW}Einzelne Datei aufrufen:${NC}"
    echo -e "  ${CYAN}https://$BUCKET.s3.amazonaws.com/DATEINAME${NC}"
    echo ""
    echo -e "${YELLOW}Erneut synchronisieren (nur Aenderungen):${NC}"
    echo -e "  ${CYAN}aws s3 sync $LOCAL_DIR s3://$BUCKET --delete${NC}"
else
    echo -e "${RED}Fehler beim Synchronisieren.${NC}"
    exit 1
fi
