#!/bin/bash

# S3 Bucket öffentlich zugänglich machen
# Usage: ./s3-make-public.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Buckets abrufen, bei Fehler manuelle Eingabe
echo -e "${YELLOW}Verfügbare S3 Buckets werden abgerufen...${NC}"
BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$')

if [ -n "$BUCKETS" ]; then
    echo ""
    echo -e "${CYAN}Verfügbare Buckets:${NC}"
    i=1
    while IFS= read -r bucket; do
        echo "  [$i] $bucket"
        BUCKET_LIST[$i]="$bucket"
        ((i++))
    done <<< "$BUCKETS"

    echo ""
    read -rp "Bucket auswählen (Nummer): " SELECTION

    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -ge "$i" ]; then
        echo -e "${RED}Fehler: Ungültige Auswahl.${NC}"
        exit 1
    fi

    BUCKET="${BUCKET_LIST[$SELECTION]}"
else
    echo -e "${YELLOW}Bucket-Liste nicht verfügbar. Bitte manuell eingeben.${NC}"
    echo ""
    read -rp "Bucket-Name: " BUCKET

    if [ -z "$BUCKET" ]; then
        echo -e "${RED}Fehler: Kein Bucket-Name eingegeben.${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${YELLOW}Schritt 1: Public Access Block deaktivieren...${NC}"
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Fehler beim Deaktivieren des Public Access Blocks.${NC}"
    exit 1
fi

echo -e "${GREEN}Public Access Block deaktiviert.${NC}"

echo ""
echo -e "${YELLOW}Schritt 2: Bucket Policy setzen (öffentlich lesbar)...${NC}"
aws s3api put-bucket-policy \
    --bucket "$BUCKET" \
    --policy "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Principal\": \"*\",
            \"Action\": \"s3:GetObject\",
            \"Resource\": \"arn:aws:s3:::${BUCKET}/*\"
        }]
    }" 2>&1

if [ $? -ne 0 ]; then
    echo -e "${RED}Fehler beim Setzen der Bucket Policy.${NC}"
    exit 1
fi

echo -e "${GREEN}Bucket Policy gesetzt.${NC}"

# Bucket-Region ermitteln
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query "LocationConstraint" --output text 2>/dev/null)
[ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" == "None" ] && BUCKET_REGION="us-east-1"

echo ""
echo -e "${GREEN}Bucket '$BUCKET' ist jetzt öffentlich zugänglich!${NC}"
echo ""
echo -e "Dateien sind erreichbar unter:"
if [ "$BUCKET_REGION" == "us-east-1" ]; then
    echo -e "${CYAN}https://${BUCKET}.s3.amazonaws.com/<dateiname>${NC}"
else
    echo -e "${CYAN}https://${BUCKET}.s3.${BUCKET_REGION}.amazonaws.com/<dateiname>${NC}"
fi
