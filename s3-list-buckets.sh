#!/bin/bash

# S3 Buckets anzeigen mit Details

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== S3 Buckets anzeigen ===${NC}"
echo ""

read -rp "AWS Region        [us-east-1]: " REGION
REGION="${REGION:-us-east-1}"

echo ""
echo -e "${YELLOW}Buckets werden abgerufen...${NC}"
echo ""

# ─── Alle Buckets abrufen ─────────────────────────────────────────────────────
BUCKETS=$(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>&1)

if echo "$BUCKETS" | grep -qi "error\|ExpiredToken\|AccessDenied"; then
    echo -e "${RED}Fehler beim Abrufen der Buckets:${NC}"
    echo -e "  $BUCKETS"
    exit 1
fi

if [ -z "$BUCKETS" ]; then
    echo -e "${YELLOW}Keine Buckets gefunden.${NC}"
    exit 0
fi

COUNT=0
echo -e "${BOLD}─── Verfuegbare Buckets ─────────────────────────────${NC}"
echo ""

for BUCKET in $BUCKETS; do
    COUNT=$(( COUNT + 1 ))

    # Region des Buckets ermitteln
    BUCKET_REGION=$(aws s3api get-bucket-location \
        --bucket "$BUCKET" \
        --query 'LocationConstraint' \
        --output text 2>/dev/null)
    [ "$BUCKET_REGION" == "None" ] && BUCKET_REGION="us-east-1"

    # Erstellungsdatum
    CREATED=$(aws s3api list-buckets \
        --query "Buckets[?Name=='$BUCKET'].CreationDate" \
        --output text 2>/dev/null | cut -d'T' -f1)

    # Anzahl Objekte und Gesamtgröße
    SIZE_INFO=$(aws s3 ls "s3://$BUCKET" --recursive --human-readable --summarize \
        --region "$BUCKET_REGION" 2>/dev/null | grep -E "Total Objects|Total Size")
    OBJ_COUNT=$(echo "$SIZE_INFO" | grep "Total Objects" | awk '{print $NF}')
    OBJ_SIZE=$(echo "$SIZE_INFO" | grep "Total Size" | awk '{print $(NF-1), $NF}')
    [ -z "$OBJ_COUNT" ] && OBJ_COUNT="0"
    [ -z "$OBJ_SIZE"  ] && OBJ_SIZE="0 Bytes"

    # Public Access Status
    PUBLIC=$(aws s3api get-public-access-block \
        --bucket "$BUCKET" \
        --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' \
        --output text 2>/dev/null)
    if [ "$PUBLIC" == "False" ]; then
        ACCESS="${GREEN}Oeffentlich${NC}"
    elif [ "$PUBLIC" == "True" ]; then
        ACCESS="${RED}Privat${NC}"
    else
        ACCESS="${YELLOW}Unbekannt${NC}"
    fi

    echo -e "  ${CYAN}[$COUNT] $BUCKET${NC}"
    echo -e "       Region:   $BUCKET_REGION"
    echo -e "       Erstellt: $CREATED"
    echo -e "       Objekte:  $OBJ_COUNT  ($OBJ_SIZE)"
    echo -e "       Zugriff:  $(echo -e $ACCESS)"
    echo -e "       URL:      https://$BUCKET.s3.amazonaws.com/"
    echo ""
done

echo -e "${BOLD}─────────────────────────────────────────────────────${NC}"
echo -e "  ${GREEN}Gesamt: $COUNT Bucket(s)${NC}"
echo ""
