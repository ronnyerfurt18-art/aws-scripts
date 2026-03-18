#!/bin/bash

# S3 Bucket anlegen mit public Policy

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== S3 Bucket anlegen ===${NC}"
echo ""

read -rp "AWS Region        [us-east-1]: " REGION
REGION="${REGION:-us-east-1}"

read -rp "Bucket-Name:      " BUCKET
[ -z "$BUCKET" ] && echo -e "${RED}Fehler: Kein Name angegeben.${NC}" && exit 1

echo ""
echo -e "  Region: ${CYAN}$REGION${NC}"
echo -e "  Bucket: ${CYAN}s3://$BUCKET${NC}"
echo ""
read -rp "Bucket anlegen? [j/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0
echo ""

# ─── 1. Bucket erstellen ──────────────────────────────────────────────────────
echo -e "${YELLOW}[1/3] Bucket erstellen...${NC}"
if [ "$REGION" == "us-east-1" ]; then
    RESULT=$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>&1)
else
    RESULT=$(aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" 2>&1)
fi

if echo "$RESULT" | grep -q "BucketAlreadyOwnedByYou"; then
    echo -e "  ${YELLOW}Bucket existiert bereits.${NC}"
elif echo "$RESULT" | grep -q "error\|Error"; then
    echo -e "  ${RED}Fehler: $RESULT${NC}"; exit 1
else
    echo -e "  ${GREEN}✓ Bucket erstellt${NC}"
fi

# ─── 2. Block Public Access deaktivieren ──────────────────────────────────────
echo -e "${YELLOW}[2/3] Oeffentlichen Zugriff erlauben...${NC}"
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
        "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
    --region "$REGION" > /dev/null
echo -e "  ${GREEN}✓ Block Public Access deaktiviert${NC}"

# ─── 3. Bucket Policy setzen ──────────────────────────────────────────────────
echo -e "${YELLOW}[3/3] Bucket Policy setzen...${NC}"
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

RESULT=$(aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY" --region "$REGION" 2>&1)
if echo "$RESULT" | grep -q "error\|Error"; then
    echo -e "  ${RED}Fehler: $RESULT${NC}"; exit 1
fi
echo -e "  ${GREEN}✓ Bucket Policy gesetzt (public read)${NC}"

echo ""
echo -e "${BOLD}=== Bucket bereit ===${NC}"
echo ""
echo -e "  ${GREEN}✓ Bucket:${NC}    s3://$BUCKET"
echo -e "  ${GREEN}✓ URL:${NC}       ${CYAN}https://$BUCKET.s3.amazonaws.com/${NC}"
echo ""
echo -e "${YELLOW}Dateien hochladen:${NC}"
echo -e "  ${CYAN}aws s3 cp DATEI s3://$BUCKET/${NC}"
echo -e "  ${CYAN}aws s3 sync ORDNER s3://$BUCKET/${NC}"
