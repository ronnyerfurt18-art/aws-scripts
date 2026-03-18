#!/bin/bash

# S3 Upload Script
# Usage: ./s3-upload.sh <datei> [region]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Dateipfad abfragen
echo ""
read -rp "Verzeichnispfad zur Datei (z.B. /Users/MacPro/Downloads): " FILE_DIR

if [ -z "$FILE_DIR" ]; then
    echo -e "${RED}Fehler: Kein Pfad eingegeben.${NC}"
    exit 1
fi

# Dateiname abfragen
read -rp "Dateiname mit Endung (z.B. bild.png): " FILE_NAME

if [ -z "$FILE_NAME" ]; then
    echo -e "${RED}Fehler: Kein Dateiname eingegeben.${NC}"
    exit 1
fi

FILE="${FILE_DIR%/}/${FILE_NAME}"

# Datei existiert?
if [ ! -f "$FILE" ]; then
    echo -e "${RED}Fehler: Datei '$FILE' nicht gefunden.${NC}"
    exit 1
fi

REGION="us-east-1"

# Buckets abrufen, bei Fehler manuelle Eingabe
echo ""
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

    echo ""
    echo -e "${CYAN}Region des Buckets:${NC}"
    echo "  [1] us-east-1      (US East - Virginia)"
    echo "  [2] eu-central-1   (Europa - Frankfurt)"
    echo "  [3] eu-west-1      (Europa - Irland)"
    echo "  [4] us-west-2      (US West - Oregon)"
    echo "  [5] ap-southeast-1 (Asien - Singapur)"
    echo "  [6] Andere (manuell eingeben)"
    echo ""
    read -rp "Region auswählen (Nummer): " REG_SEL

    case "$REG_SEL" in
        1) REGION="us-east-1" ;;
        2) REGION="eu-central-1" ;;
        3) REGION="eu-west-1" ;;
        4) REGION="us-west-2" ;;
        5) REGION="ap-southeast-1" ;;
        6)
            read -rp "Region eingeben: " REGION
            if [ -z "$REGION" ]; then
                echo -e "${RED}Fehler: Keine Region eingegeben.${NC}"
                exit 1
            fi
            ;;
        *)
            echo -e "${YELLOW}Ungültige Auswahl, verwende us-east-1.${NC}"
            REGION="us-east-1"
            ;;
    esac
fi

# Bucket-Region ermitteln falls aus Liste gewählt
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query "LocationConstraint" --output text 2>/dev/null)
if [ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" == "None" ]; then
    BUCKET_REGION="${REGION:-us-east-1}"
fi

FILENAME=$(basename "$FILE")

echo ""
echo -e "${YELLOW}Lade '$FILENAME' in Bucket '$BUCKET' hoch...${NC}"

aws s3 cp "$FILE" "s3://${BUCKET}/${FILENAME}" \
    --region "$BUCKET_REGION"

# Pre-Signed URL generieren (7 Tage gültig)
EXPIRES=604800
URL=$(aws s3 presign "s3://${BUCKET}/${FILENAME}" \
    --region "$BUCKET_REGION" \
    --expires-in "$EXPIRES")

echo ""
echo -e "${GREEN}Erfolgreich hochgeladen!${NC}"
echo -e "Zugriffs-URL (7 Tage gültig):"
echo -e "${GREEN}${URL}${NC}"
