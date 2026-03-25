#!/bin/bash

# JSON-Datei mit konfigurierbaren Feldern erstellen

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

echo -e "${BOLD}=== JSON-Datei erstellen ===${NC}"
echo ""

# ─── Anzahl Felder ────────────────────────────────────────────────────────────
while true; do
    read -rp "Wie viele Felder? " FIELD_COUNT
    [[ "$FIELD_COUNT" =~ ^[1-9][0-9]*$ ]] && break
    echo -e "${RED}Bitte eine positive Zahl eingeben.${NC}"
done

echo ""
echo -e "${BOLD}─── Felder definieren ───────────────────────────────${NC}"

declare -a KEYS VALUES

for ((i=1; i<=FIELD_COUNT; i++)); do
    read -rp "Feld $i - Schluessel: " KEY
    [ -z "$KEY" ] && echo -e "${RED}Schluessel darf nicht leer sein.${NC}" && ((i--)) && continue
    KEYS[$i]="$KEY"
done

echo ""
echo -e "${BOLD}─── Werte eingeben ──────────────────────────────────${NC}"
echo ""

for ((i=1; i<=FIELD_COUNT; i++)); do
    read -rp "  ${KEYS[$i]}: " VAL
    VALUES[$i]="$VAL"
done

# ─── Ausgabedatei ─────────────────────────────────────────────────────────────
echo ""
read -rp "Dateiname [student.json]: " OUTFILE
OUTFILE="${OUTFILE:-student.json}"

# ─── JSON bauen ───────────────────────────────────────────────────────────────
{
    echo "{"
    for ((i=1; i<=FIELD_COUNT; i++)); do
        # Escape Anführungszeichen im Wert
        ESCAPED="${VALUES[$i]//\"/\\\"}"
        if (( i < FIELD_COUNT )); then
            echo "  \"${KEYS[$i]}\": \"$ESCAPED\","
        else
            echo "  \"${KEYS[$i]}\": \"$ESCAPED\""
        fi
    done
    echo "}"
} > "$OUTFILE"

echo ""
echo -e "${BOLD}─── Ergebnis ────────────────────────────────────────${NC}"
echo ""
cat "$OUTFILE"
echo ""
echo -e "${GREEN}✓ Gespeichert: ${CYAN}$OUTFILE${NC}"
echo ""
