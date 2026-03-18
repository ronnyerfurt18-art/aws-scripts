#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

show_status() {
    local ENV1="$SCRIPT_DIR/01_output.env"
    local ENV2="$SCRIPT_DIR/02_output.env"

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

    if [ -f "$ENV2" ] && grep -q "INSTANCE_ID_" "$ENV2" 2>/dev/null; then
        source "$ENV2"
        echo ""
        for ((n=1; n<=SUBNET_COUNT; n++)); do
            IID_VAR="INSTANCE_ID_$n"; SN_NAME_VAR="SN_NAME_$n"; SN_TYPE_VAR="SN_TYPE_$n"
            IID="${!IID_VAR}"
            [ -z "$IID" ] && continue
            STATE=$(aws ec2 describe-instances --instance-ids "$IID" \
                --query "Reservations[0].Instances[0].State.Name" \
                --output text --region "$REGION" 2>/dev/null)
            PUB=$(aws ec2 describe-instances --instance-ids "$IID" \
                --query "Reservations[0].Instances[0].PublicIpAddress" \
                --output text --region "$REGION" 2>/dev/null)
            PRIV=$(aws ec2 describe-instances --instance-ids "$IID" \
                --query "Reservations[0].Instances[0].PrivateIpAddress" \
                --output text --region "$REGION" 2>/dev/null)
            [ "$STATE" == "running" ] && S="${GREEN}●${NC}" || S="${RED}●${NC}"
            echo -e "  $S ec2-${!SN_NAME_VAR} [${!SN_TYPE_VAR}]  priv: ${CYAN}$PRIV${NC}  pub: ${CYAN}${PUB:-–}${NC}"
        done
    fi
}

while true; do
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           AWS VPC Lab – Hauptmenü               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}─── Aktueller Status ────────────────────────────────${NC}"
    show_status
    echo ""
    echo -e "${BOLD}─── AWS Session ─────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[1]${NC} AWS Academy Credentials aktualisieren"
    echo -e "      ${DIM}→ Credentials aus Learner Lab einfuegen + automatisch speichern${NC}"
    echo ""
    echo -e "${BOLD}─── Setup ───────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[2]${NC} VPC + Subnetze + Security Groups erstellen"
    echo -e "      ${DIM}→ 01_vpc-setup.sh${NC}"
    echo -e "  ${CYAN}[3]${NC} EC2 Instanzen starten"
    echo -e "      ${DIM}→ 02_ec2-setup.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Informationen ───────────────────────────────────${NC}"
    echo -e "  ${CYAN}[4]${NC} IPs und Status aller Instanzen anzeigen"
    echo -e "      ${DIM}→ 03_get-ips.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Deployment ──────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[5]${NC} httpd installieren + index.html auf allen Instanzen"
    echo -e "      ${DIM}→ 07_install-httpd.sh  (private via Jump Host)${NC}"
    echo -e "  ${CYAN}[6]${NC} index.html per SSH deployen (nur public)"
    echo -e "      ${DIM}→ 04_deploy-content.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Klausur / Demo ──────────────────────────────────${NC}"
    echo -e "  ${CYAN}[7]${NC} Zugriffstests fuer Screenshots"
    echo -e "      ${DIM}→ 06_demo-screenshot.sh${NC}"
    echo -e "      ${DIM}  Test 1: curl von aussen → schlaegt fehl${NC}"
    echo -e "      ${DIM}  Test 2: curl auf public  → klappt${NC}"
    echo -e "      ${DIM}  Test 3: curl via Jump Host auf private → klappt${NC}"
    echo ""
    echo -e "${BOLD}─── S3 ──────────────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[8]${NC} S3 Bucket anlegen (mit public Policy)"
    echo -e "      ${DIM}→ ../s3-create-bucket.sh${NC}"
    echo -e "  ${CYAN}[9]${NC} Lokalen Ordner mit S3 Bucket synchronisieren"
    echo -e "      ${DIM}→ ../s3-sync.sh${NC}"
    echo ""
    echo -e "${BOLD}─── Aufraumen ───────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[10]${NC} ${RED}Alle Ressourcen loeschen (Teardown)${NC}"
    echo -e "       ${DIM}→ 05_teardown.sh${NC}"
    echo ""
    echo -e "  ${CYAN}[0]${NC} Beenden"
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
    read -rp "Auswahl: " CHOICE

    case "$CHOICE" in
        1)  bash "$SCRIPT_DIR/../aws-credentials-update.sh" ;;
        2)  bash "$SCRIPT_DIR/01_vpc-setup.sh" ;;
        3)  bash "$SCRIPT_DIR/02_ec2-setup.sh" ;;
        4)  bash "$SCRIPT_DIR/03_get-ips.sh" ;;
        5)  bash "$SCRIPT_DIR/07_install-httpd.sh" ;;
        6)  bash "$SCRIPT_DIR/04_deploy-content.sh" ;;
        7)  bash "$SCRIPT_DIR/06_demo-screenshot.sh" ;;
        8)  bash "$SCRIPT_DIR/../s3-create-bucket.sh" ;;
        9)  bash "$SCRIPT_DIR/../s3-sync.sh" ;;
        10) bash "$SCRIPT_DIR/05_teardown.sh" ;;
        0)  echo -e "${GREEN}Tschuess!${NC}"; exit 0 ;;
        *)  echo -e "${RED}Ungueltige Auswahl.${NC}"; sleep 1 ;;
    esac

    echo ""
    read -rp "Enter druecken um zum Menue zurueckzukehren..."
done
