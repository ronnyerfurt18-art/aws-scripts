#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.env"
STATUS_CACHE="$SCRIPT_DIR/status.cache"

# Globale Konfiguration laden
[ -f "$CONFIG" ] && source "$CONFIG"
[ -z "$REGION" ] && REGION="us-east-1"

# ─── Instanz-Status per AWS abfragen und cachen ───────────────────────────────
refresh_status() {
    echo -e "${YELLOW}Lade Instanz-Status (alle Instanzen in $REGION)...${NC}"

    local RAW
    RAW=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query "Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress,PrivateIpAddress,Tags[?Key=='Name']|[0].Value]" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$RAW" ]; then
        echo -e "${YELLOW}Keine Instanzen gefunden.${NC}"; return
    fi

    echo "CACHE_TS=$(date '+%H:%M:%S')" > "$STATUS_CACHE"
    local IDX=0
    while IFS=$'\t' read -r IID STATE PUB PRIV NAME; do
        [ "$PUB"   == "None" ] && PUB=""
        [ "$PRIV"  == "None" ] && PRIV=""
        [ "$NAME"  == "None" ] && NAME="$IID"
        {
            echo "CACHE_IID_$IDX=$IID"
            echo "CACHE_NAME_$IDX=$NAME"
            echo "CACHE_STATE_$IDX=$STATE"
            echo "CACHE_PUB_$IDX=$PUB"
            echo "CACHE_PRIV_$IDX=$PRIV"
        } >> "$STATUS_CACHE"
        echo -e "  ${GREEN}✓${NC} $NAME  $STATE"
        (( IDX++ ))
    done <<< "$RAW"
    echo "CACHE_COUNT=$IDX" >> "$STATUS_CACHE"
    echo -e "${GREEN}✓ $IDX Instanz(en) gespeichert${NC}"
}

# ─── Status anzeigen – KEINE AWS-Abfragen, nur .env + Cache lesen ────────────
show_status() {
    local ENV1="$SCRIPT_DIR/01_output.env"
    local ENV2="$SCRIPT_DIR/02_output.env"

    # VPC / Subnetze – aus .env, sofort
    if [ -f "$ENV1" ] && grep -q "VPC_ID=vpc-" "$ENV1" 2>/dev/null; then
        source "$ENV1"
        echo -e "  VPC:     ${GREEN}$VPC_ID${NC}  ($VPC_CIDR)"
        [ -n "$IGW_ID" ] && echo -e "  IGW:     ${GREEN}$IGW_ID${NC}"
        for ((n=1; n<=SUBNET_COUNT; n++)); do
            SN_NAME_VAR="SN_NAME_$n"; SN_TYPE_VAR="SN_TYPE_$n"; SID_VAR="SUBNET_ID_$n"
            case "${!SN_TYPE_VAR}" in
                public)  T="${GREEN}public${NC}" ;;
                private) T="${RED}private${NC}" ;;
                none)    T="${YELLOW}isoliert${NC}" ;;
            esac
            echo -e "  Subnetz: ${CYAN}${!SN_NAME_VAR}${NC} (${!SID_VAR}) → $T"
        done
    else
        echo -e "  ${DIM}Kein aktives Setup gefunden.${NC}"
    fi

    # Instanzen – aus Cache, keine API-Abfrage
    echo ""
    if [ -f "$STATUS_CACHE" ]; then
        source "$STATUS_CACHE"
        echo -e "  ${DIM}Instanz-Status (Stand: $CACHE_TS)  –  [r] aktualisieren${NC}"
        for ((i=0; i<CACHE_COUNT; i++)); do
            N_IID="CACHE_IID_$i"; N_NAME="CACHE_NAME_$i"
            N_STATE="CACHE_STATE_$i"; N_PUB="CACHE_PUB_$i"; N_PRIV="CACHE_PRIV_$i"
            STATE="${!N_STATE:-?}"
            [ "$STATE" == "running" ] && S="${GREEN}●${NC}" || S="${RED}●${NC}"
            echo -e "  $S ${!N_NAME}  priv: ${CYAN}${!N_PRIV:--}${NC}  pub: ${CYAN}${!N_PUB:--}${NC}"
        done
    else
        echo -e "  ${DIM}[r] druecken fuer Instanz-Statusabfrage${NC}"
    fi
}

# ─── Region + Key-Name konfigurieren ─────────────────────────────────────────
configure() {
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           Konfiguration                         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Aktuelle Region:   ${CYAN}$REGION${NC}"
    echo -e "  Aktiver Key-Name:  ${CYAN}${KEY_NAME:-(nicht gesetzt)}${NC}"
    echo ""
    echo -e "  ${DIM}Einfach Enter druecken = Wert behalten${NC}"
    echo ""
    read -rp "  Neue Region  [$REGION]: " NEW_REGION
    NEW_REGION="${NEW_REGION:-$REGION}"

    read -rp "  Key-Name     [${KEY_NAME:-(leer)}]: " NEW_KEY
    NEW_KEY="${NEW_KEY:-$KEY_NAME}"

    # config.env schreiben
    cat > "$CONFIG" <<EOF
# AWS VPC Lab – globale Konfiguration
REGION=$NEW_REGION
KEY_NAME=$NEW_KEY
EOF

    REGION="$NEW_REGION"
    KEY_NAME="$NEW_KEY"

    # Cache loeschen wenn Region geaendert (anderer Account/Region)
    [ "$NEW_REGION" != "$REGION" ] && rm -f "$STATUS_CACHE"

    echo ""
    echo -e "${GREEN}✓ Gespeichert:  Region=${CYAN}$REGION${NC}  Key=${CYAN}${KEY_NAME:-(leer)}${NC}"
}

# ══════════════════════════════════════════════════════════════════════════════
# HAUPTMENUE
# ══════════════════════════════════════════════════════════════════════════════
while true; do
    # config neu laden (falls durch 00_create-keypair geaendert)
    [ -f "$CONFIG" ] && source "$CONFIG"
    [ -z "$REGION" ] && REGION="us-east-1"

    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           AWS VPC Lab – Hauptmenue              ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "  Region: ${CYAN}$REGION${NC}   Key: ${CYAN}${KEY_NAME:-(nicht gesetzt)}${NC}   ${DIM}[2] aendern  [4] EC2-Manager${NC}"
    echo ""
    echo -e "${BOLD}─── Aktueller Status ────────────────────────────────${NC}"
    show_status
    echo ""
    echo -e "${BOLD}─── Vorbereitung ────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[1]${NC}  AWS Academy Credentials aktualisieren"
    echo -e "       ${DIM}→ Credentials aus Learner Lab einfuegen${NC}"
    echo -e "  ${CYAN}[2]${NC}  Region + Key-Name konfigurieren"
    echo -e "  ${CYAN}[3]${NC}  Key Pair erstellen / auswaehlen"
    echo -e "       ${DIM}→ 00_create-keypair.sh${NC}"
    echo ""
    echo -e "${BOLD}─── EC2 (allgemein) ─────────────────────────────────${NC}"
    echo -e "  ${CYAN}[4]${NC}  EC2 Instanzen verwalten  ${DIM}(Linux + Windows, Start/Stop/Neu)${NC}"
    echo -e "       ${DIM}→ 10_ec2-manager.sh${NC}"
    echo ""
    echo -e "${BOLD}─── VPC Lab Setup ───────────────────────────────────${NC}"
    echo -e "  ${CYAN}[5]${NC}  VPC + Subnetze + Security Groups erstellen"
    echo -e "       ${DIM}→ 01_vpc-setup.sh  (Port 80 hier konfigurieren!)${NC}"
    echo -e "  ${CYAN}[6]${NC}  EC2 Lab-Instanzen starten"
    echo -e "       ${DIM}→ 02_ec2-setup.sh${NC}"
    echo -e "       ${DIM}  Startet je eine Instanz pro Subnetz. Jede Instanz bekommt${NC}"
    echo -e "       ${DIM}  einen eigenen Text (z.B. 'Hallo, ich bin eine private Instanz').${NC}"
    echo -e "       ${DIM}  Dieser Text wird per HTTP abrufbar:  curl http://<IP>${NC}"
    echo -e "       ${DIM}  Apache (httpd) wird beim Start automatisch installiert (User-Data).${NC}"
    echo ""
    echo -e "${BOLD}─── SSH & Tunnel ────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[7]${NC}  PEM uebertragen + SSH-Tunnel-Befehle anzeigen"
    echo -e "       ${DIM}→ 12_ssh-tunnel.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Deployment ──────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[8]${NC}  httpd installieren + index.html  ${DIM}(benoetigt Port 80 offen)${NC}"
    echo -e "       ${DIM}→ 07_install-httpd.sh  (private via Jump Host)${NC}"
    echo -e "  ${CYAN}[9]${NC}  index.html per SSH deployen (nur public)"
    echo -e "       ${DIM}→ 04_deploy-content.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Netzwerk ────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[10]${NC} Security Groups verwalten  ${DIM}(Instanz-Ebene, stateful)${NC}"
    echo -e "       ${DIM}→ 08_security-groups.sh  (Port 80 nachtraeglich aendern)${NC}"
    echo -e "  ${CYAN}[11]${NC} Network ACLs verwalten     ${DIM}(Subnetz-Ebene, stateless)${NC}"
    echo -e "       ${DIM}→ 09_network-acl.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Informationen ───────────────────────────────────${NC}"
    echo -e "  ${CYAN}[12]${NC} IPs und Status aller Lab-Instanzen anzeigen"
    echo -e "       ${DIM}→ 03_get-ips.sh${NC}"
    echo -e "  ${CYAN}[13]${NC} Schritt-Anleitung anzeigen  ${DIM}(Ablauf des Labs)${NC}"
    echo -e "       ${DIM}→ 11_lab-guide.sh${NC}"
    echo -e "  ${CYAN}[14]${NC} VPC-Diagramm generieren  ${DIM}(HTML/SVG im Browser)${NC}"
    echo -e "       ${DIM}→ 13_diagram.sh${NC}"
    if [ -f "$SCRIPT_DIR/vpc-diagram.html" ]; then
        echo -e "       ${GREEN}✓ Diagramm vorhanden:${NC} ${CYAN}file://$SCRIPT_DIR/vpc-diagram.html${NC}"
    fi
    echo -e "  ${CYAN}[r]${NC}  Status im Menue aktualisieren  ${DIM}(AWS-Abfrage)${NC}"
    echo ""
    echo -e "${BOLD}─── Klausur / Demo ──────────────────────────────────${NC}"
    echo -e "  ${CYAN}[15]${NC} Zugriffstests fuer Screenshots"
    echo -e "       ${DIM}→ 06_demo-screenshot.sh${NC}"
    echo ""
    echo -e "${BOLD}─── S3 ──────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[16]${NC} S3 Bucket anlegen (mit public Policy)"
    echo -e "       ${DIM}→ ../s3-create-bucket.sh${NC}"
    echo -e "  ${CYAN}[17]${NC} Lokalen Ordner mit S3 Bucket synchronisieren"
    echo -e "       ${DIM}→ ../s3-sync.sh${NC}"
    echo -e "  ${CYAN}[18]${NC} S3 Buckets anzeigen"
    echo -e "       ${DIM}→ ../s3-list-buckets.sh${NC}"
    echo -e "  ${CYAN}[19]${NC} JSON-Datei erstellen  ${DIM}(Name, Matrikel, Bucket ...)${NC}"
    echo -e "       ${DIM}→ ../s3-student-json.sh${NC}"
    echo -e "  ${CYAN}[20]${NC} Einzelne Datei in S3 hochladen"
    echo -e "       ${DIM}→ ../s3-upload-datei.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Aufraeumen ──────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[21]${NC} ${RED}Ressourcen loeschen / Teardown${NC}"
    echo -e "       ${DIM}→ 05_teardown.sh  (einzeln oder alles – Auswahl im naechsten Schritt)${NC}"
    echo ""
    echo -e "  ${CYAN}[0]${NC}  Beenden"
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
    read -rp "Auswahl: " CHOICE

    case "$CHOICE" in
        1)  bash "$SCRIPT_DIR/../aws-credentials-update.sh" ;;
        2)  configure; sleep 1; continue ;;
        3)  bash "$SCRIPT_DIR/00_create-keypair.sh" ;;
        4)  bash "$SCRIPT_DIR/10_ec2-manager.sh" ;;
        5)  bash "$SCRIPT_DIR/01_vpc-setup.sh" ;;
        6)  bash "$SCRIPT_DIR/02_ec2-setup.sh" ;;
        7)  bash "$SCRIPT_DIR/12_ssh-tunnel.sh" ;;
        8)  bash "$SCRIPT_DIR/07_install-httpd.sh" ;;
        9)  bash "$SCRIPT_DIR/04_deploy-content.sh" ;;
        10) bash "$SCRIPT_DIR/08_security-groups.sh" ;;
        11) bash "$SCRIPT_DIR/09_network-acl.sh" ;;
        12) bash "$SCRIPT_DIR/03_get-ips.sh" ;;
        13) bash "$SCRIPT_DIR/11_lab-guide.sh" ;;
        14) bash "$SCRIPT_DIR/13_diagram.sh" ;;
        15) bash "$SCRIPT_DIR/06_demo-screenshot.sh" ;;
        16) bash "$SCRIPT_DIR/../s3-create-bucket.sh" ;;
        17) bash "$SCRIPT_DIR/../s3-sync.sh" ;;
        18) bash "$SCRIPT_DIR/../s3-list-buckets.sh" ;;
        19) bash "$SCRIPT_DIR/../s3-student-json.sh" ;;
        20) bash "$SCRIPT_DIR/../s3-upload-datei.sh" ;;
        21) bash "$SCRIPT_DIR/05_teardown.sh" ;;
        r|R) clear; refresh_status; read -rp "Enter zum Fortfahren..." ; continue ;;
        0)  echo -e "${GREEN}Tschuess!${NC}"; exit 0 ;;
        *)  echo -e "${RED}Ungueltige Auswahl.${NC}"; sleep 1; continue ;;
    esac

    echo ""
    read -rp "Enter druecken um zum Menue zurueckzukehren..."
done
