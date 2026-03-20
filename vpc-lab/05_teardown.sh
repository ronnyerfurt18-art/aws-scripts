#!/bin/bash

# SCHRITT 5: Ressourcen loeschen (selektiv oder vollstaendig)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_01="$SCRIPT_DIR/01_output.env"
OUTPUT_02="$SCRIPT_DIR/02_output.env"

if [ ! -f "$OUTPUT_01" ] || ! grep -q "VPC_ID=vpc-" "$OUTPUT_01" 2>/dev/null; then
    echo -e "${RED}Fehler: Kein aktives Setup gefunden (01_output.env leer).${NC}"
    exit 1
fi

source "$OUTPUT_01"
[ -f "$OUTPUT_02" ] && source "$OUTPUT_02"

# ─── Uebersicht aktueller Ressourcen ──────────────────────────────────────────
clear
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           Teardown – Ressourcen loeschen        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}─── Aktuelle Ressourcen ─────────────────────────────${NC}"
echo -e "  ${DIM}Prüfe AWS...${NC}"

# VPC-Existenzcheck (einmalig – alle Ressourcen sind VPC-scoped)
VPC_CHECK=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query "Vpcs[0].VpcId" --output text 2>&1)
if echo "$VPC_CHECK" | grep -qE "NotFound|does not exist|None|-$"; then
    VPC_EXISTS=false
else
    VPC_EXISTS=true
fi

printf "\r\033[K"  # Zeile "Prüfe AWS..." überschreiben
echo -e "  VPC:    ${CYAN}$VPC_ID${NC}  ($VPC_CIDR)  Region: $REGION"
! $VPC_EXISTS && echo -e "  ${YELLOW}Hinweis: VPC existiert nicht mehr in AWS – .env enthält veraltete IDs.${NC}"
echo ""

# EC2 Instanzen
EC2_FOUND=false
for ((n=1; n<=SUBNET_COUNT; n++)); do
    IID_VAR="INSTANCE_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
    IID="${!IID_VAR}"
    if [ -n "$IID" ]; then
        INFO=$(aws ec2 describe-instances --instance-ids "$IID" \
            --query "Reservations[0].Instances[0].[InstanceType,Platform,State.Name]" \
            --output text --region "$REGION" 2>/dev/null)
        ITYPE=$(echo "$INFO" | awk '{print $1}')
        PLATFORM=$(echo "$INFO" | awk '{print $2}')
        ISTATE=$(echo "$INFO" | awk '{print $3}')
        [ "$PLATFORM" == "None" ] || [ -z "$PLATFORM" ] && PLATFORM="Linux"
        if [ -z "$ISTATE" ] || [ "$ISTATE" == "None" ] || [ "$ISTATE" == "terminated" ]; then
            echo -e "  ${DIM}[1] EC2  ec2-${!SN_NAME_VAR}: $IID  [bereits terminiert]${NC}"
        elif [ "$ISTATE" == "running" ]; then
            echo -e "  [1] EC2  ec2-${!SN_NAME_VAR}: ${CYAN}$IID${NC}  ${DIM}$ITYPE / $PLATFORM${NC}  ${GREEN}$ISTATE${NC}"
        else
            echo -e "  [1] EC2  ec2-${!SN_NAME_VAR}: ${CYAN}$IID${NC}  ${DIM}$ITYPE / $PLATFORM${NC}  ${YELLOW}$ISTATE${NC}"
        fi
        EC2_FOUND=true
    fi
done
$EC2_FOUND || echo -e "  ${DIM}[1] EC2  – keine Instanzen${NC}"

# Security Groups
echo ""
SG_FOUND=false
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SG_VAR="SG_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
    SG="${!SG_VAR}"
    if [ -n "$SG" ]; then
        if $VPC_EXISTS; then
            echo -e "  [2] SG   sec-${!SN_NAME_VAR}: ${CYAN}$SG${NC}"
        else
            echo -e "  ${DIM}[2] SG   sec-${!SN_NAME_VAR}: $SG  [bereits geloescht]${NC}"
        fi
        SG_FOUND=true
    fi
done
$SG_FOUND || echo -e "  ${DIM}[2] SG   – keine Security Groups${NC}"

# Subnetze
echo ""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SID_VAR="SUBNET_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
    SID="${!SID_VAR}"
    if [ -n "$SID" ]; then
        if $VPC_EXISTS; then
            echo -e "  [3] SN   ${!SN_NAME_VAR}: ${CYAN}$SID${NC}"
        else
            echo -e "  ${DIM}[3] SN   ${!SN_NAME_VAR}: $SID  [bereits geloescht]${NC}"
        fi
    fi
done

# Route Tables
echo ""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    RT_VAR="RT_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
    RT="${!RT_VAR}"
    if [ -n "$RT" ]; then
        if $VPC_EXISTS; then
            echo -e "  [4] RT   rt-${!SN_NAME_VAR}: ${CYAN}$RT${NC}"
        else
            echo -e "  ${DIM}[4] RT   rt-${!SN_NAME_VAR}: $RT  [bereits geloescht]${NC}"
        fi
    fi
done

# IGW
echo ""
if [ -n "$IGW_ID" ]; then
    if $VPC_EXISTS; then
        echo -e "  [5] IGW  ${CYAN}$IGW_ID${NC}"
    else
        echo -e "  ${DIM}[5] IGW  $IGW_ID  [bereits geloescht]${NC}"
    fi
else
    echo -e "  ${DIM}[5] IGW  – nicht vorhanden${NC}"
fi

# VPC
echo ""
if $VPC_EXISTS; then
    echo -e "  [6] VPC  ${CYAN}$VPC_ID${NC}  ${DIM}(setzt [2][3][4][5] voraus)${NC}"
else
    echo -e "  ${DIM}[6] VPC  $VPC_ID  [bereits geloescht]${NC}"
fi

# ENV
echo ""
echo -e "  [7] .env Dateien leeren  ${DIM}(01_output.env + 02_output.env)${NC}"

echo ""
echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
echo -e "  ${RED}[A]${NC} Alles loeschen  ${DIM}(vollstaendiger Teardown, 1→7)${NC}"
echo -e "  ${CYAN}Nummern${NC} kommagetrennt eingeben  ${DIM}(z.B. 1  oder  1,2  oder  1,2,6,7)${NC}"
echo -e "  [0] Abbrechen"
echo ""
read -rp "Auswahl: " RAW_SEL

[ "$RAW_SEL" == "0" ] && echo -e "${YELLOW}Abgebrochen.${NC}" && exit 0

# Auswahl aufloesen
if [[ "$RAW_SEL" =~ ^[Aa]$ ]]; then
    STEPS=(1 2 3 4 5 6 7)
else
    IFS=',' read -ra PARTS <<< "$RAW_SEL"
    STEPS=()
    for P in "${PARTS[@]}"; do
        P=$(echo "$P" | tr -d ' ')
        [[ "$P" =~ ^[1-7]$ ]] && STEPS+=("$P")
    done
    if [ ${#STEPS[@]} -eq 0 ]; then
        echo -e "${RED}Keine gueltige Auswahl.${NC}"; exit 1
    fi
fi

# Zusammenfassung
echo ""
echo -e "${BOLD}─── Zu loeschen ─────────────────────────────────────${NC}"
for S in "${STEPS[@]}"; do
    case "$S" in
        1) echo -e "  ${RED}✗${NC} EC2 Instanzen terminieren" ;;
        2) echo -e "  ${RED}✗${NC} Security Groups loeschen" ;;
        3) echo -e "  ${RED}✗${NC} Subnetze loeschen" ;;
        4) echo -e "  ${RED}✗${NC} Route Tables loeschen" ;;
        5) echo -e "  ${RED}✗${NC} Internet Gateway loeschen" ;;
        6) echo -e "  ${RED}✗${NC} VPC loeschen" ;;
        7) echo -e "  ${RED}✗${NC} .env Dateien leeren" ;;
    esac
done
echo ""
read -rp "Wirklich loeschen? [j/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${YELLOW}Abgebrochen.${NC}" && exit 0
echo ""

# ─── Hilfsfunktion: Schritt enthalten? ────────────────────────────────────────
has_step() {
    local S="$1"
    for X in "${STEPS[@]}"; do [ "$X" == "$S" ] && return 0; done
    return 1
}

# ─── Hilfsfunktion: Fehler klassifizieren ─────────────────────────────────────
# Gibt 0=Erfolg, 1=NotFound (bereits weg), 2=echter Fehler zurück
classify_result() {
    local RESULT="$1"
    [ -z "$RESULT" ] && return 0
    echo "$RESULT" | grep -qE "NotFound|does not exist" && return 1
    echo "$RESULT" | grep -qiE "error|Error" && return 2
    return 0
}

# ─── 1. EC2 terminieren ───────────────────────────────────────────────────────
if has_step 1; then
    echo -e "${YELLOW}[1] EC2 Instanzen terminieren...${NC}"
    INSTANCE_IDS_LIST=()
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        IID_VAR="INSTANCE_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
        IID="${!IID_VAR}"
        if [ -n "$IID" ]; then
            RESULT=$(aws ec2 terminate-instances --instance-ids "$IID" --region "$REGION" \
                --query "TerminatingInstances[0].CurrentState.Name" --output text 2>&1)
            if echo "$RESULT" | grep -qE "NotFound|does not exist|terminated"; then
                echo -e "  ${DIM}ec2-${!SN_NAME_VAR}: $IID  [bereits terminiert]${NC}"
            else
                echo -e "  ${GREEN}ec2-${!SN_NAME_VAR}${NC}: $IID → wird terminiert"
                INSTANCE_IDS_LIST+=("$IID")
            fi
        fi
    done
    if [ ${#INSTANCE_IDS_LIST[@]} -gt 0 ]; then
        echo -e "  ${DIM}Warte auf Terminierung...${NC}"
        aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS_LIST[@]}" --region "$REGION"
        echo -e "  ${GREEN}✓ Alle Instanzen terminiert.${NC}"
    else
        echo -e "  ${DIM}Keine aktiven Instanzen – nichts zu tun.${NC}"
    fi
fi

# ─── 2. Security Groups loeschen ──────────────────────────────────────────────
if has_step 2; then
    echo -e "${YELLOW}[2] Security Groups loeschen...${NC}"
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        SG_VAR="SG_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
        SG="${!SG_VAR}"
        if [ -n "$SG" ]; then
            RESULT=$(aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>&1)
            classify_result "$RESULT"
            case $? in
                0) echo -e "  ${GREEN}✓ sec-${!SN_NAME_VAR}${NC}: $SG geloescht" ;;
                1) echo -e "  ${DIM}  sec-${!SN_NAME_VAR}: $SG  [bereits geloescht]${NC}" ;;
                2) echo -e "  ${RED}  Fehler sec-${!SN_NAME_VAR}: $RESULT${NC}" ;;
            esac
        fi
    done
fi

# ─── 3. Subnetze loeschen ─────────────────────────────────────────────────────
if has_step 3; then
    echo -e "${YELLOW}[3] Subnetze loeschen...${NC}"
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        SID_VAR="SUBNET_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
        SID="${!SID_VAR}"
        if [ -n "$SID" ]; then
            RESULT=$(aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" 2>&1)
            classify_result "$RESULT"
            case $? in
                0) echo -e "  ${GREEN}✓ ${!SN_NAME_VAR}${NC}: $SID geloescht" ;;
                1) echo -e "  ${DIM}  ${!SN_NAME_VAR}: $SID  [bereits geloescht]${NC}" ;;
                2) echo -e "  ${RED}  Fehler ${!SN_NAME_VAR}: $RESULT${NC}" ;;
            esac
        fi
    done
fi

# ─── 4. Route Tables loeschen ─────────────────────────────────────────────────
if has_step 4; then
    echo -e "${YELLOW}[4] Route Tables loeschen...${NC}"
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        RT_VAR="RT_ID_$n"; SN_NAME_VAR="SN_NAME_$n"
        RT="${!RT_VAR}"
        if [ -n "$RT" ]; then
            RESULT=$(aws ec2 delete-route-table --route-table-id "$RT" --region "$REGION" 2>&1)
            classify_result "$RESULT"
            case $? in
                0) echo -e "  ${GREEN}✓ rt-${!SN_NAME_VAR}${NC}: $RT geloescht" ;;
                1) echo -e "  ${DIM}  rt-${!SN_NAME_VAR}: $RT  [bereits geloescht]${NC}" ;;
                2) echo -e "  ${RED}  Fehler rt-${!SN_NAME_VAR}: $RESULT${NC}" ;;
            esac
        fi
    done
fi

# ─── 5. Internet Gateway ──────────────────────────────────────────────────────
if has_step 5; then
    if [ -n "$IGW_ID" ]; then
        echo -e "${YELLOW}[5] Internet Gateway loeschen...${NC}"
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null
        RESULT=$(aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" 2>&1)
        classify_result "$RESULT"
        case $? in
            0) echo -e "  ${GREEN}✓ IGW${NC}: $IGW_ID geloescht" ;;
            1) echo -e "  ${DIM}  IGW: $IGW_ID  [bereits geloescht]${NC}" ;;
            2) echo -e "  ${RED}  Fehler IGW: $RESULT${NC}" ;;
        esac
    else
        echo -e "${DIM}[5] Kein Internet Gateway – uebersprungen.${NC}"
    fi
fi

# ─── 6. VPC loeschen ──────────────────────────────────────────────────────────
if has_step 6; then
    echo -e "${YELLOW}[6] VPC loeschen...${NC}"
    RESULT=$(aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>&1)
    classify_result "$RESULT"
    case $? in
        0) echo -e "  ${GREEN}✓ VPC${NC}: $VPC_ID geloescht" ;;
        1) echo -e "  ${DIM}  VPC: $VPC_ID  [bereits geloescht]${NC}" ;;
        2) echo -e "  ${RED}  Fehler VPC: $RESULT${NC}"
           echo -e "  ${YELLOW}  Tipp: Erst SG [2], Subnetze [3], RT [4], IGW [5] loeschen.${NC}" ;;
    esac
fi

# ─── 7. .env Dateien leeren ───────────────────────────────────────────────────
if has_step 7; then
    echo -e "${YELLOW}[7] .env Dateien leeren...${NC}"
    > "$OUTPUT_01" && echo -e "  ${GREEN}✓ 01_output.env geleert${NC}"
    [ -f "$OUTPUT_02" ] && > "$OUTPUT_02" && echo -e "  ${GREEN}✓ 02_output.env geleert${NC}"
    # Status-Cache ebenfalls loeschen
    [ -f "$SCRIPT_DIR/status.cache" ] && rm -f "$SCRIPT_DIR/status.cache" && echo -e "  ${GREEN}✓ status.cache geloescht${NC}"
fi

echo ""
echo -e "${BOLD}=== Teardown abgeschlossen ===${NC}"
