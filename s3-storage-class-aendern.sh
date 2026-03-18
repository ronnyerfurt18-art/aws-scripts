#!/bin/bash

# S3 Storage Class Changer
# Usage: ./s3-storage-class.sh [--help]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --help
if [ "${1}" == "--help" ]; then
    echo ""
    echo -e "${BOLD}S3 Speicherklassen – Übersicht${NC}"
    echo ""
    echo -e "${CYAN}STANDARD${NC}"
    echo "  Standard-Speicherklasse. Hohe Verfügbarkeit und Langlebigkeit."
    echo "  Geeignet für häufig abgerufene Daten."
    echo ""
    echo -e "${CYAN}INTELLIGENT_TIERING${NC}"
    echo "  Verschiebt Daten automatisch zwischen Zugriffsschichten."
    echo "  Kostenoptimiert bei unbekanntem Zugriffsmuster."
    echo ""
    echo -e "${CYAN}STANDARD_IA${NC}"
    echo "  Standard Infrequent Access. Günstigerer Speicher für"
    echo "  selten abgerufene Daten. Mindestabrufgebühr."
    echo ""
    echo -e "${CYAN}ONEZONE_IA${NC}"
    echo "  Wie STANDARD_IA, aber nur in einer Availability Zone."
    echo "  Günstiger, geringere Ausfallsicherheit."
    echo ""
    echo -e "${CYAN}GLACIER_IR${NC}"
    echo "  Glacier Instant Retrieval. Archiv mit sofortigem Zugriff."
    echo "  Für Daten, die selten aber schnell abgerufen werden."
    echo ""
    echo -e "${CYAN}GLACIER${NC}"
    echo "  Glacier Flexible Retrieval. Günstigstes Archiv."
    echo "  Abruf dauert Minuten bis Stunden."
    echo ""
    echo -e "${CYAN}DEEP_ARCHIVE${NC}"
    echo "  Günstigste Speicherklasse. Abruf dauert 12–48 Stunden."
    echo "  Für Langzeitarchivierung (z.B. Compliance-Daten)."
    echo ""
    echo -e "${CYAN}REDUCED_REDUNDANCY${NC}"
    echo "  Veraltet. Geringere Redundanz, nicht empfohlen."
    echo ""
    echo -e "Verwendung: ${BOLD}$0${NC}"
    echo ""
    exit 0
fi

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

# Bucket-Region ermitteln
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query "LocationConstraint" --output text 2>/dev/null)
[ "$BUCKET_REGION" == "None" ] && BUCKET_REGION="us-east-1"

# Dateien im Bucket auflisten (Fallback: manuelle Eingabe)
echo ""
echo -e "${YELLOW}Dateien in Bucket '$BUCKET' werden abgerufen...${NC}"
FILES=$(aws s3api list-objects-v2 --bucket "$BUCKET" --query "Contents[].{Key:Key,Class:StorageClass}" --output text 2>/dev/null)

if [ -n "$FILES" ]; then
    echo ""
    j=1
    while IFS=$'\t' read -r class key; do
        echo "  [$j] $key  ${CYAN}(${class})${NC}"
        FILE_LIST[$j]="$key"
        ((j++))
    done <<< "$FILES"

    echo ""
    read -rp "Datei auswählen (Nummer): " FILE_SEL

    if ! [[ "$FILE_SEL" =~ ^[0-9]+$ ]] || [ "$FILE_SEL" -lt 1 ] || [ "$FILE_SEL" -ge "$j" ]; then
        echo -e "${RED}Fehler: Ungültige Auswahl.${NC}"
        exit 1
    fi

    TARGET_KEY="${FILE_LIST[$FILE_SEL]}"
else
    echo -e "${YELLOW}Dateiliste nicht verfügbar. Bitte manuell eingeben.${NC}"
    echo ""
    read -rp "Dateiname im Bucket (z.B. bild.png): " TARGET_KEY

    if [ -z "$TARGET_KEY" ]; then
        echo -e "${RED}Fehler: Kein Dateiname eingegeben.${NC}"
        exit 1
    fi
fi

# Speicherklasse auswählen
echo ""
echo -e "${CYAN}Verfügbare Speicherklassen:${NC}"
CLASSES=(STANDARD INTELLIGENT_TIERING STANDARD_IA ONEZONE_IA GLACIER_IR GLACIER DEEP_ARCHIVE)
k=1
for cls in "${CLASSES[@]}"; do
    echo "  [$k] $cls"
    ((k++))
done

echo ""
read -rp "Speicherklasse auswählen (Nummer): " CLASS_SEL

if ! [[ "$CLASS_SEL" =~ ^[0-9]+$ ]] || [ "$CLASS_SEL" -lt 1 ] || [ "$CLASS_SEL" -ge "$k" ]; then
    echo -e "${RED}Fehler: Ungültige Auswahl.${NC}"
    exit 1
fi

NEW_CLASS="${CLASSES[$((CLASS_SEL - 1))]}"

# Speicherklasse ändern (Objekt auf sich selbst kopieren)
echo ""
echo -e "${YELLOW}Ändere Speicherklasse von '$TARGET_KEY' zu '$NEW_CLASS'...${NC}"

aws s3 cp "s3://${BUCKET}/${TARGET_KEY}" "s3://${BUCKET}/${TARGET_KEY}" \
    --storage-class "$NEW_CLASS" \
    --region "$BUCKET_REGION" \
    --metadata-directive COPY 2>&1

echo ""
echo -e "${GREEN}Speicherklasse erfolgreich geändert!${NC}"
echo -e "  Bucket:          ${CYAN}${BUCKET}${NC}"
echo -e "  Datei:           ${CYAN}${TARGET_KEY}${NC}"
echo -e "  Neue Klasse:     ${GREEN}${NEW_CLASS}${NC}"
