#!/bin/bash

# S3 Sync – Verzeichnisse synchronisieren (lokal↔S3, S3↔S3)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Globale Konfiguration laden (Region)
[ -f "$SCRIPT_DIR/vpc-lab/config.env" ] && source "$SCRIPT_DIR/vpc-lab/config.env"
[ -z "$REGION" ] && REGION="us-east-1"

# ─── Hilfsfunktion: Bucket auswaehlen ────────────────────────────────────────
# Zeigt Bucket-Liste an, laesst auswaehlen, zeigt Inhalt, gibt Name zurueck
# Alle Anzeige geht nach stderr (&2), nur der Name nach stdout
select_bucket() {
    local LABEL="$1"

    echo "" >&2
    echo -e "${YELLOW}${LABEL} – Verfuegbare S3 Buckets:${NC}" >&2
    local BUCKETS
    BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$')

    if [ -z "$BUCKETS" ]; then
        echo -e "${YELLOW}Bucket-Liste nicht verfuegbar. Bitte manuell eingeben.${NC}" >&2
        read -rp "  Bucket-Name: " SELECTED_BUCKET
        [ -z "$SELECTED_BUCKET" ] && echo -e "${RED}Fehler: Kein Bucket angegeben.${NC}" >&2 && exit 1
        echo "$SELECTED_BUCKET"
        return
    fi

    local i=1
    local -a BL
    while IFS= read -r b; do
        # Objektanzahl – aws s3 ls handled regional redirects automatically
        local COUNT
        COUNT=$(aws s3 ls "s3://$b/" --recursive 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$COUNT" ] && COUNT=0
        echo -e "  [${CYAN}$i${NC}] $b  ${YELLOW}($COUNT Objekte)${NC}" >&2
        BL[$i]="$b"
        ((i++))
    done <<< "$BUCKETS"
    echo -e "  [${CYAN}0${NC}] Abbrechen" >&2
    echo "" >&2

    read -rp "  Bucket auswaehlen (Nummer): " SEL

    [ "$SEL" == "0" ] && echo -e "${YELLOW}Abgebrochen.${NC}" >&2 && exit 0

    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -lt "$i" ]; then
        local SELECTED_BUCKET="${BL[$SEL]}"
    else
        echo -e "${RED}Ungueltige Auswahl.${NC}" >&2
        exit 1
    fi

    # ─── Inhalt des gewaehlten Buckets anzeigen ──────────────────────────────
    echo "" >&2
    echo -e "${CYAN}Inhalt von s3://$SELECTED_BUCKET :${NC}" >&2

    local FILES
    FILES=$(aws s3 ls "s3://$SELECTED_BUCKET/" --recursive --human-readable 2>/dev/null | head -20)

    if [ -n "$FILES" ]; then
        local TOTAL
        TOTAL=$(aws s3 ls "s3://$SELECTED_BUCKET/" --recursive 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$TOTAL" ] && TOTAL=0

        echo "$FILES" | while IFS= read -r line; do
            echo -e "  $line" >&2
        done

        if [ "$TOTAL" -gt 20 ]; then
            echo -e "  ${YELLOW}... und $(( TOTAL - 20 )) weitere Objekte${NC}" >&2
        fi
        echo -e "  ${GREEN}Gesamt: $TOTAL Objekte${NC}" >&2
    else
        echo -e "  ${YELLOW}(leer – falscher Bucket?)${NC}" >&2
        read -rp "  Trotzdem fortfahren? [j/N]: " CONT >&2
        [[ ! "$CONT" =~ ^[JjYy]$ ]] && echo -e "${YELLOW}Abgebrochen.${NC}" >&2 && exit 0
    fi

    echo "$SELECTED_BUCKET"
}

# ─── Hilfsfunktion: Bucket-Inhalt mit Nummerierung anzeigen (fuer Teilsync) ─
# Gibt die Keys als Array in BUCKET_FILES zurueck
show_bucket_files() {
    local BUCKET_NAME="$1"
    local PREFIX="$2"

    local S3_PATH="s3://$BUCKET_NAME"
    [ -n "$PREFIX" ] && S3_PATH="s3://$BUCKET_NAME/${PREFIX%/}"

    echo "" >&2
    echo -e "${CYAN}Dateien in $S3_PATH :${NC}" >&2

    # aws s3 ls handles regional redirects automatically (no --region needed)
    local RAW
    RAW=$(aws s3 ls "$S3_PATH" --recursive --human-readable 2>/dev/null)

    BUCKET_FILES=()
    BUCKET_FILE_COUNT=0

    if [ -z "$RAW" ]; then
        echo -e "  ${YELLOW}(keine Dateien gefunden)${NC}" >&2
        return
    fi

    local j=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # aws s3 ls --human-readable output: DATE TIME  SIZE UNIT  KEY
        local key size_info
        key=$(echo "$line" | awk '{print $NF}')
        size_info=$(echo "$line" | awk '{print $3, $4}')
        echo -e "  [${CYAN}$j${NC}] $key  ${YELLOW}($size_info)${NC}" >&2
        BUCKET_FILES[$j]="$key"
        ((j++))
    done <<< "$RAW"

    BUCKET_FILE_COUNT=$(( j - 1 ))
    echo -e "  ${GREEN}Gesamt: $BUCKET_FILE_COUNT Dateien${NC}" >&2
}

# ══════════════════════════════════════════════════════════════════════════════
# START
# ══════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}=== S3 Sync ===${NC}"
echo ""
echo -e "${CYAN}Sync-Richtung waehlen:${NC}"
echo -e "  [1] Lokal → S3      (Ordner auf Rechner → S3 Bucket)"
echo -e "  [2] S3 → Lokal      (S3 Bucket → Ordner auf Rechner)"
echo -e "  [3] S3 → S3         (Bucket A → Bucket B)"
echo ""
read -rp "Auswahl [1/2/3]: " SYNC_MODE

case "$SYNC_MODE" in
    1) MODE="local_to_s3" ;;
    2) MODE="s3_to_local" ;;
    3) MODE="s3_to_s3" ;;
    *)
        echo -e "${RED}Ungueltige Auswahl.${NC}"
        exit 1
        ;;
esac

# ─── Region ──────────────────────────────────────────────────────────────────
echo ""
read -rp "AWS Region             [$REGION]:  " INPUT_REGION
REGION="${INPUT_REGION:-$REGION}"

# ─── Modus-spezifische Parameter ────────────────────────────────────────────

case "$MODE" in

# ══════════════════════════════════════════════════════════════════════════════
# MODUS 1: Lokal → S3
# ══════════════════════════════════════════════════════════════════════════════
local_to_s3)
    echo ""
    read -rp "Lokaler Ordner-Pfad:   " LOCAL_DIR
    LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"
    [ ! -d "$LOCAL_DIR" ] && echo -e "${RED}Fehler: Ordner '$LOCAL_DIR' nicht gefunden.${NC}" && exit 1

    BUCKET=$(select_bucket "Ziel-Bucket")

    # Optional: Unterordner im Bucket
    echo ""
    read -rp "Unterordner im Bucket (leer = Root): " S3_PREFIX
    S3_TARGET="s3://$BUCKET"
    [ -n "$S3_PREFIX" ] && S3_TARGET="s3://$BUCKET/${S3_PREFIX%/}"

    FILE_COUNT=$(find "$LOCAL_DIR" -type f | wc -l | tr -d ' ')

    # ─── Delete-Option ───────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}Geloeschte Dateien am Ziel auch loeschen? (--delete)${NC}"
    echo -e "  [1] Nein  – nur neue/geaenderte Dateien uebertragen (sicher)"
    echo -e "  [2] Ja    – Ziel wird exakte Kopie der Quelle"
    read -rp "Auswahl [1]: " DEL_SEL
    DELETE_FLAG=""
    [ "$DEL_SEL" == "2" ] && DELETE_FLAG="--delete"

    echo ""
    echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────${NC}"
    echo -e "  Richtung:      ${CYAN}Lokal → S3${NC}"
    echo -e "  Quelle:        ${CYAN}$LOCAL_DIR${NC}  ($FILE_COUNT Dateien)"
    echo -e "  Ziel:          ${CYAN}$S3_TARGET${NC}"
    echo -e "  Region:        ${CYAN}$REGION${NC}"
    [ -n "$DELETE_FLAG" ] && echo -e "  --delete:      ${RED}JA${NC}"
    echo ""
    read -rp "Sync starten? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0

    echo ""
    echo -e "${YELLOW}Synchronisiere...${NC}"
    aws s3 sync "$LOCAL_DIR" "$S3_TARGET" \
        --region "$REGION" \
        --exclude ".DS_Store" \
        --exclude "*.pem" \
        --exclude "*.key" \
        $DELETE_FLAG

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ Sync abgeschlossen: Lokal → S3${NC}"
        echo -e "  ${CYAN}$S3_TARGET${NC}"
    else
        echo -e "${RED}Fehler beim Synchronisieren.${NC}"
        exit 1
    fi
    ;;

# ══════════════════════════════════════════════════════════════════════════════
# MODUS 2: S3 → Lokal
# ══════════════════════════════════════════════════════════════════════════════
s3_to_local)
    BUCKET=$(select_bucket "Quell-Bucket")

    echo ""
    read -rp "Unterordner im Bucket (leer = alles): " S3_PREFIX

    # Dateien im Bucket anzeigen
    show_bucket_files "$BUCKET" "$S3_PREFIX"

    S3_SOURCE="s3://$BUCKET"
    [ -n "$S3_PREFIX" ] && S3_SOURCE="s3://$BUCKET/${S3_PREFIX%/}"

    # ─── Auswahl: alle oder nur bestimmte Dateien? ───────────────────────
    SYNC_SPECIFIC=false
    INCLUDE_FLAGS=""
    if [ "$BUCKET_FILE_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${CYAN}Was synchronisieren?${NC}"
        echo -e "  [1] Alle Dateien"
        echo -e "  [2] Nur bestimmte Dateien auswaehlen"
        read -rp "Auswahl [1]: " PARTIAL_SEL

        if [ "$PARTIAL_SEL" == "2" ]; then
            SYNC_SPECIFIC=true
            echo ""
            echo -e "${YELLOW}Nummern der Dateien eingeben (kommagetrennt, z.B. 1,3,5):${NC}"
            read -rp "  Auswahl: " FILE_NUMS

            IFS=',' read -ra NUMS <<< "$FILE_NUMS"
            for NUM in "${NUMS[@]}"; do
                NUM=$(echo "$NUM" | tr -d ' ')
                if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le "$BUCKET_FILE_COUNT" ]; then
                    KEY="${BUCKET_FILES[$NUM]}"
                    # Prefix abschneiden fuer --include Pattern
                    if [ -n "$S3_PREFIX" ]; then
                        PATTERN="${KEY#${S3_PREFIX%/}/}"
                    else
                        PATTERN="$KEY"
                    fi
                    INCLUDE_FLAGS="$INCLUDE_FLAGS --include \"$PATTERN\""
                    echo -e "  ${GREEN}✓${NC} $KEY"
                else
                    echo -e "  ${RED}Uebersprungen: $NUM${NC}"
                fi
            done
        fi
    fi

    echo ""
    read -rp "Lokaler Ziel-Ordner:   " LOCAL_DIR
    LOCAL_DIR="${LOCAL_DIR/#\~/$HOME}"

    if [ ! -d "$LOCAL_DIR" ]; then
        echo -e "${YELLOW}Ordner existiert nicht. Erstelle: $LOCAL_DIR${NC}"
        mkdir -p "$LOCAL_DIR"
    fi

    # ─── Delete-Option ───────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}Geloeschte Dateien am Ziel auch loeschen? (--delete)${NC}"
    echo -e "  [1] Nein  – nur neue/geaenderte Dateien uebertragen (sicher)"
    echo -e "  [2] Ja    – Ziel wird exakte Kopie der Quelle"
    read -rp "Auswahl [1]: " DEL_SEL
    DELETE_FLAG=""
    [ "$DEL_SEL" == "2" ] && DELETE_FLAG="--delete"

    echo ""
    echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────${NC}"
    echo -e "  Richtung:      ${CYAN}S3 → Lokal${NC}"
    echo -e "  Quelle:        ${CYAN}$S3_SOURCE${NC}"
    echo -e "  Ziel:          ${CYAN}$LOCAL_DIR${NC}"
    echo -e "  Region:        ${CYAN}$REGION${NC}"
    if $SYNC_SPECIFIC; then
        echo -e "  Auswahl:       ${CYAN}Nur ausgewaehlte Dateien${NC}"
    else
        echo -e "  Auswahl:       ${CYAN}Alle Dateien${NC}"
    fi
    [ -n "$DELETE_FLAG" ] && echo -e "  --delete:      ${RED}JA${NC}"
    echo ""
    read -rp "Sync starten? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0

    echo ""
    echo -e "${YELLOW}Synchronisiere...${NC}"

    if $SYNC_SPECIFIC; then
        # Bei Einzelauswahl: aws s3 cp fuer jede Datei
        for NUM in "${NUMS[@]}"; do
            NUM=$(echo "$NUM" | tr -d ' ')
            if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le "$BUCKET_FILE_COUNT" ]; then
                KEY="${BUCKET_FILES[$NUM]}"
                DEST_FILE="$LOCAL_DIR/$(basename "$KEY")"
                echo -e "  ${CYAN}$KEY${NC} → $DEST_FILE"
                aws s3 cp "s3://$BUCKET/$KEY" "$DEST_FILE" --region "$REGION"
            fi
        done
    else
        aws s3 sync "$S3_SOURCE" "$LOCAL_DIR" \
            --region "$REGION" \
            $DELETE_FLAG
    fi

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ Sync abgeschlossen: S3 → Lokal${NC}"
        echo -e "  ${CYAN}$LOCAL_DIR${NC}"
    else
        echo -e "${RED}Fehler beim Synchronisieren.${NC}"
        exit 1
    fi
    ;;

# ══════════════════════════════════════════════════════════════════════════════
# MODUS 3: S3 → S3
# ══════════════════════════════════════════════════════════════════════════════
s3_to_s3)
    BUCKET_SRC=$(select_bucket "Quell-Bucket")

    echo ""
    read -rp "Unterordner im Quell-Bucket (leer = alles): " SRC_PREFIX

    # Dateien im Quell-Bucket anzeigen
    show_bucket_files "$BUCKET_SRC" "$SRC_PREFIX"

    S3_SOURCE="s3://$BUCKET_SRC"
    [ -n "$SRC_PREFIX" ] && S3_SOURCE="s3://$BUCKET_SRC/${SRC_PREFIX%/}"

    # ─── Auswahl: alle oder nur bestimmte Dateien? ───────────────────────
    SYNC_SPECIFIC=false
    declare -a SELECTED_KEYS
    if [ "$BUCKET_FILE_COUNT" -gt 0 ]; then
        echo ""
        echo -e "${CYAN}Was synchronisieren?${NC}"
        echo -e "  [1] Alle Dateien"
        echo -e "  [2] Nur bestimmte Dateien auswaehlen"
        read -rp "Auswahl [1]: " PARTIAL_SEL

        if [ "$PARTIAL_SEL" == "2" ]; then
            SYNC_SPECIFIC=true
            echo ""
            echo -e "${YELLOW}Nummern der Dateien eingeben (kommagetrennt, z.B. 1,3,5):${NC}"
            read -rp "  Auswahl: " FILE_NUMS

            IFS=',' read -ra NUMS <<< "$FILE_NUMS"
            for NUM in "${NUMS[@]}"; do
                NUM=$(echo "$NUM" | tr -d ' ')
                if [[ "$NUM" =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le "$BUCKET_FILE_COUNT" ]; then
                    SELECTED_KEYS+=("${BUCKET_FILES[$NUM]}")
                    echo -e "  ${GREEN}✓${NC} ${BUCKET_FILES[$NUM]}"
                else
                    echo -e "  ${RED}Uebersprungen: $NUM${NC}"
                fi
            done
        fi
    fi

    BUCKET_DST=$(select_bucket "Ziel-Bucket")

    echo ""
    read -rp "Unterordner im Ziel-Bucket (leer = Root): " DST_PREFIX
    S3_TARGET="s3://$BUCKET_DST"
    [ -n "$DST_PREFIX" ] && S3_TARGET="s3://$BUCKET_DST/${DST_PREFIX%/}"

    # ─── Delete-Option ───────────────────────────────────────────────────
    echo ""
    echo -e "${YELLOW}Geloeschte Dateien am Ziel auch loeschen? (--delete)${NC}"
    echo -e "  [1] Nein  – nur neue/geaenderte Dateien uebertragen (sicher)"
    echo -e "  [2] Ja    – Ziel wird exakte Kopie der Quelle"
    read -rp "Auswahl [1]: " DEL_SEL
    DELETE_FLAG=""
    [ "$DEL_SEL" == "2" ] && DELETE_FLAG="--delete"

    echo ""
    echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────${NC}"
    echo -e "  Richtung:      ${CYAN}S3 → S3${NC}"
    echo -e "  Quelle:        ${CYAN}$S3_SOURCE${NC}"
    echo -e "  Ziel:          ${CYAN}$S3_TARGET${NC}"
    echo -e "  Region:        ${CYAN}$REGION${NC}"
    if $SYNC_SPECIFIC; then
        echo -e "  Auswahl:       ${CYAN}${#SELECTED_KEYS[@]} Dateien${NC}"
    else
        echo -e "  Auswahl:       ${CYAN}Alle Dateien${NC}"
    fi
    [ -n "$DELETE_FLAG" ] && echo -e "  --delete:      ${RED}JA${NC}"
    echo ""
    read -rp "Sync starten? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0

    echo ""
    echo -e "${YELLOW}Synchronisiere...${NC}"

    if $SYNC_SPECIFIC; then
        # Einzelne Dateien kopieren
        for KEY in "${SELECTED_KEYS[@]}"; do
            DEST_KEY="$(basename "$KEY")"
            [ -n "$DST_PREFIX" ] && DEST_KEY="${DST_PREFIX%/}/$DEST_KEY"
            echo -e "  ${CYAN}$KEY${NC} → s3://$BUCKET_DST/$DEST_KEY"
            aws s3 cp "s3://$BUCKET_SRC/$KEY" "s3://$BUCKET_DST/$DEST_KEY" --region "$REGION"
        done
    else
        aws s3 sync "$S3_SOURCE" "$S3_TARGET" \
            --region "$REGION" \
            $DELETE_FLAG
    fi

    if [ $? -eq 0 ]; then
        echo ""
        echo -e "${GREEN}✓ Sync abgeschlossen: S3 → S3${NC}"
        echo -e "  ${CYAN}$S3_SOURCE${NC} → ${CYAN}$S3_TARGET${NC}"
    else
        echo -e "${RED}Fehler beim Synchronisieren.${NC}"
        exit 1
    fi
    ;;

esac

echo ""
echo -e "${YELLOW}Tipp: Erneut synchronisieren (nur Aenderungen):${NC}"
echo -e "  ${CYAN}aws s3 sync <QUELLE> <ZIEL> --delete${NC}"
echo ""
