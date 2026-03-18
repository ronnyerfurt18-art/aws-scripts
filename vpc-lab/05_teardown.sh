#!/bin/bash

# SCHRITT 5: Alle Ressourcen loeschen (Teardown)
# Liest IDs aus 01_output.env und 02_output.env

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_01="$SCRIPT_DIR/01_output.env"
OUTPUT_02="$SCRIPT_DIR/02_output.env"

if [ ! -f "$OUTPUT_01" ]; then
    echo -e "${RED}Fehler: 01_output.env nicht gefunden.${NC}"
    exit 1
fi

source "$OUTPUT_01"
[ -f "$OUTPUT_02" ] && source "$OUTPUT_02"

echo -e "${BOLD}=== Schritt 5: Teardown ===${NC}"
echo ""
echo -e "  VPC:    ${CYAN}$VPC_ID${NC}  ($VPC_CIDR)"
echo -e "  Region: ${CYAN}$REGION${NC}"
echo ""
echo -e "${RED}WARNUNG: Alle folgenden Ressourcen werden unwiderruflich geloescht!${NC}"
echo ""

read -rp "Wirklich loeschen? [j/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0
echo ""

# ─── 1. EC2 Instanzen terminieren ─────────────────────────────────────────────
if [ -n "$SUBNET_COUNT" ]; then
    echo -e "${YELLOW}[1] EC2 Instanzen terminieren...${NC}"
    INSTANCE_IDS_LIST=()
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        IID_VAR="INSTANCE_ID_$n"
        IID="${!IID_VAR}"
        SN_NAME_VAR="SN_NAME_$n"
        if [ -n "$IID" ]; then
            aws ec2 terminate-instances --instance-ids "$IID" --region "$REGION" \
                --query "TerminatingInstances[0].CurrentState.Name" --output text 2>/dev/null
            echo -e "  ${GREEN}ec2-${!SN_NAME_VAR}${NC}: $IID → wird terminiert"
            INSTANCE_IDS_LIST+=("$IID")
        fi
    done

    if [ ${#INSTANCE_IDS_LIST[@]} -gt 0 ]; then
        echo -e "  Warte auf Terminierung..."
        aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS_LIST[@]}" --region "$REGION"
        echo -e "  ${GREEN}Alle Instanzen terminiert.${NC}"
    fi
else
    echo -e "${YELLOW}[1] Keine Instanzen in 02_output.env – uebersprungen.${NC}"
fi

# ─── 2. Security Groups loeschen ──────────────────────────────────────────────
echo -e "${YELLOW}[2] Security Groups loeschen...${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SG_VAR="SG_ID_$n"
    SN_NAME_VAR="SN_NAME_$n"
    SG="${!SG_VAR}"
    if [ -n "$SG" ]; then
        RESULT=$(aws ec2 delete-security-group --group-id "$SG" --region "$REGION" 2>&1)
        if echo "$RESULT" | grep -q "error\|Error"; then
            echo -e "  ${RED}Fehler sec-${!SN_NAME_VAR}: $RESULT${NC}"
        else
            echo -e "  ${GREEN}sec-${!SN_NAME_VAR}${NC}: $SG geloescht"
        fi
    fi
done

# ─── 3. Subnetze loeschen ─────────────────────────────────────────────────────
echo -e "${YELLOW}[3] Subnetze loeschen...${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SID_VAR="SUBNET_ID_$n"
    SN_NAME_VAR="SN_NAME_$n"
    SID="${!SID_VAR}"
    if [ -n "$SID" ]; then
        RESULT=$(aws ec2 delete-subnet --subnet-id "$SID" --region "$REGION" 2>&1)
        if echo "$RESULT" | grep -q "error\|Error"; then
            echo -e "  ${RED}Fehler ${!SN_NAME_VAR}: $RESULT${NC}"
        else
            echo -e "  ${GREEN}${!SN_NAME_VAR}${NC}: $SID geloescht"
        fi
    fi
done

# ─── 4. Route Tables loeschen ─────────────────────────────────────────────────
echo -e "${YELLOW}[4] Route Tables loeschen...${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    RT_VAR="RT_ID_$n"
    SN_NAME_VAR="SN_NAME_$n"
    RT="${!RT_VAR}"
    if [ -n "$RT" ]; then
        RESULT=$(aws ec2 delete-route-table --route-table-id "$RT" --region "$REGION" 2>&1)
        if echo "$RESULT" | grep -q "error\|Error"; then
            echo -e "  ${RED}Fehler rt-${!SN_NAME_VAR}: $RESULT${NC}"
        else
            echo -e "  ${GREEN}rt-${!SN_NAME_VAR}${NC}: $RT geloescht"
        fi
    fi
done

# ─── 5. Internet Gateway detachen und loeschen ────────────────────────────────
if [ -n "$IGW_ID" ]; then
    echo -e "${YELLOW}[5] Internet Gateway loeschen...${NC}"
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null
    RESULT=$(aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" 2>&1)
    if echo "$RESULT" | grep -q "error\|Error"; then
        echo -e "  ${RED}Fehler IGW: $RESULT${NC}"
    else
        echo -e "  ${GREEN}IGW${NC}: $IGW_ID geloescht"
    fi
else
    echo -e "${YELLOW}[5] Kein Internet Gateway vorhanden.${NC}"
fi

# ─── 6. VPC loeschen ──────────────────────────────────────────────────────────
echo -e "${YELLOW}[6] VPC loeschen...${NC}"
RESULT=$(aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>&1)
if echo "$RESULT" | grep -q "error\|Error"; then
    echo -e "  ${RED}Fehler VPC: $RESULT${NC}"
    echo -e "  ${YELLOW}Tipp: Moeglicherweise gibt es noch abhaengige Ressourcen.${NC}"
else
    echo -e "  ${GREEN}VPC${NC}: $VPC_ID geloescht"
fi

# ─── 7. .env Dateien aufraumen ────────────────────────────────────────────────
echo -e "${YELLOW}[7] .env Dateien aufraumen...${NC}"
> "$OUTPUT_01" && echo -e "  ${GREEN}01_output.env geleert${NC}"
[ -f "$OUTPUT_02" ] && > "$OUTPUT_02" && echo -e "  ${GREEN}02_output.env geleert${NC}"

echo ""
echo -e "${BOLD}=== Teardown abgeschlossen ===${NC}"
