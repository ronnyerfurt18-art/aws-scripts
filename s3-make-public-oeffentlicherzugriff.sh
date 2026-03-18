#!/bin/bash

# S3 Bucket: Oeffentlichen Zugriff freigeben ODER einschraenken
# Gibt am Ende den HTTP-Link aus zum Testen (Zugriff oder "Access Denied")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== S3 Bucket – Zugriff verwalten ===${NC}"
echo ""
echo -e "${CYAN}Was moechtest du tun?${NC}"
echo -e "  [1] Bucket oeffentlich machen   (Public Read – jeder kann per HTTP zugreifen)"
echo -e "  [2] Bucket einschraenken         (Zugriff sperren – HTTP liefert 'Access Denied')"
echo ""
read -rp "Auswahl [1/2]: " ACTION

case "$ACTION" in
    1) MODE="public" ;;
    2) MODE="private" ;;
    *)
        echo -e "${RED}Ungueltige Auswahl.${NC}"
        exit 1
        ;;
esac

# ─── Bucket auswaehlen ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Verfuegbare S3 Buckets werden abgerufen...${NC}"
BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$')

if [ -n "$BUCKETS" ]; then
    echo ""
    echo -e "${CYAN}Verfuegbare Buckets:${NC}"
    i=1
    while IFS= read -r bucket; do
        echo "  [$i] $bucket"
        BUCKET_LIST[$i]="$bucket"
        ((i++))
    done <<< "$BUCKETS"

    echo ""
    read -rp "Bucket auswaehlen (Nummer): " SELECTION

    if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -ge "$i" ]; then
        echo -e "${RED}Fehler: Ungueltige Auswahl.${NC}"
        exit 1
    fi

    BUCKET="${BUCKET_LIST[$SELECTION]}"
else
    echo -e "${YELLOW}Bucket-Liste nicht verfuegbar. Bitte manuell eingeben.${NC}"
    echo ""
    read -rp "Bucket-Name: " BUCKET

    if [ -z "$BUCKET" ]; then
        echo -e "${RED}Fehler: Kein Bucket-Name eingegeben.${NC}"
        exit 1
    fi
fi

# Bucket-Region ermitteln
BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" --query "LocationConstraint" --output text 2>/dev/null)
[ -z "$BUCKET_REGION" ] || [ "$BUCKET_REGION" == "None" ] && BUCKET_REGION="us-east-1"

# URL bestimmen
if [ "$BUCKET_REGION" == "us-east-1" ]; then
    BASE_URL="https://${BUCKET}.s3.amazonaws.com"
else
    BASE_URL="https://${BUCKET}.s3.${BUCKET_REGION}.amazonaws.com"
fi

# ─── Dateien im Bucket auflisten (fuer den Test-Link) ───────────────────────
echo ""
echo -e "${YELLOW}Dateien im Bucket werden abgerufen...${NC}"
FILES=$(aws s3api list-objects-v2 --bucket "$BUCKET" --query "Contents[].Key" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | head -10)

FIRST_FILE=""
if [ -n "$FILES" ]; then
    echo ""
    echo -e "${CYAN}Dateien im Bucket (max. 10):${NC}"
    while IFS= read -r f; do
        echo "  - $f"
        [ -z "$FIRST_FILE" ] && FIRST_FILE="$f"
    done <<< "$FILES"
fi

# ══════════════════════════════════════════════════════════════════════════════
if [ "$MODE" == "public" ]; then
# ══════════════════════════════════════════════════════════════════════════════

    echo ""
    echo -e "${YELLOW}[1/2] Public Access Block deaktivieren...${NC}"
    aws s3api put-public-access-block \
        --bucket "$BUCKET" \
        --public-access-block-configuration \
        "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}Fehler beim Deaktivieren des Public Access Blocks.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ Public Access Block deaktiviert${NC}"

    echo -e "${YELLOW}[2/2] Bucket Policy setzen (public read)...${NC}"
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
    echo -e "  ${GREEN}✓ Bucket Policy gesetzt (s3:GetObject fuer alle)${NC}"

    echo ""
    echo -e "${GREEN}═══ Bucket '$BUCKET' ist jetzt OEFFENTLICH zugaenglich ═══${NC}"

# ══════════════════════════════════════════════════════════════════════════════
else
# ══════════════════════════════════════════════════════════════════════════════

    echo ""
    echo -e "${YELLOW}[1/2] Bucket Policy entfernen...${NC}"
    aws s3api delete-bucket-policy --bucket "$BUCKET" 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}Fehler beim Entfernen der Bucket Policy.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ Bucket Policy entfernt${NC}"

    echo -e "${YELLOW}[2/2] Public Access Block aktivieren...${NC}"
    aws s3api put-public-access-block \
        --bucket "$BUCKET" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}Fehler beim Aktivieren des Public Access Blocks.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓ Public Access Block aktiviert (alles gesperrt)${NC}"

    echo ""
    echo -e "${RED}═══ Bucket '$BUCKET' ist jetzt EINGESCHRAENKT (kein oeffentlicher Zugriff) ═══${NC}"

fi

# ─── Test-Links ausgeben ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── HTTP-Test-Links ─────────────────────────────${NC}"
echo ""

if [ -n "$FIRST_FILE" ]; then
    TEST_URL="${BASE_URL}/${FIRST_FILE}"
    echo -e "  Erste Datei testen:"
    echo -e "  ${CYAN}${TEST_URL}${NC}"
    echo ""

    if [ "$MODE" == "public" ]; then
        echo -e "  ${GREEN}Erwartet: Datei wird angezeigt / heruntergeladen${NC}"
    else
        echo -e "  ${RED}Erwartet: AccessDenied (403 Forbidden)${NC}"
    fi
else
    echo -e "  ${YELLOW}Keine Dateien im Bucket gefunden.${NC}"
    echo -e "  Lade eine Datei hoch und teste dann:"
    echo -e "  ${CYAN}${BASE_URL}/<dateiname>${NC}"
fi

echo ""
echo -e "${YELLOW}Allgemein: ${CYAN}${BASE_URL}/<dateiname>${NC}"
echo ""

# ─── Quick-Test mit curl ─────────────────────────────────────────────────────
if [ -n "$FIRST_FILE" ]; then
    echo -e "${BOLD}─── Quick-Test (curl) ───────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}curl -I ${TEST_URL}${NC}"
    echo ""
    read -rp "Jetzt testen? [j/N]: " DO_TEST
    if [[ "$DO_TEST" =~ ^[JjYy]$ ]]; then
        echo ""
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TEST_URL" 2>/dev/null)
        if [ "$HTTP_CODE" == "200" ]; then
            echo -e "  ${GREEN}HTTP $HTTP_CODE – Zugriff OK (oeffentlich)${NC}"
        elif [ "$HTTP_CODE" == "403" ]; then
            echo -e "  ${RED}HTTP $HTTP_CODE – Access Denied (eingeschraenkt)${NC}"
        else
            echo -e "  ${YELLOW}HTTP $HTTP_CODE${NC}"
        fi
        echo ""
    fi
fi
