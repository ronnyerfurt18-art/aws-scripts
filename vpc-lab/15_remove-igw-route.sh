#!/bin/bash

# IGW-Route aus privatem Subnetz entfernen
# Nuetzlich nach: httpd installiert + index.html hochgeladen
# Danach: Subnetz ist wirklich privat (kein ausgehender Internetzugang mehr)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/01_output.env"

[ -f "$SCRIPT_DIR/config.env" ] && source "$SCRIPT_DIR/config.env"
[ -z "$REGION" ] && REGION="us-east-1"

if [ ! -f "$OUTPUT_FILE" ] || ! grep -q "VPC_ID=vpc-" "$OUTPUT_FILE" 2>/dev/null; then
    echo -e "${RED}Kein aktives VPC-Setup gefunden (01_output.env fehlt oder leer).${NC}"
    exit 1
fi
source "$OUTPUT_FILE"

echo -e "${BOLD}=== IGW-Route aus privatem Subnetz entfernen ===${NC}"
echo ""
echo -e "  ${DIM}Workflow: Privates Subnetz mit IGW anlegen → httpd installieren${NC}"
echo -e "  ${DIM}          → index.html hochladen → IGW-Route hier entfernen${NC}"
echo ""

# Subnetze mit IGW anzeigen
declare -a CANDIDATES_N
IDX=0
for ((n=1; n<=SUBNET_COUNT; n++)); do
    HAS_IGW_VAR="SN_HAS_IGW_$n"
    TYPE_VAR="SN_TYPE_$n"
    NAME_VAR="SN_NAME_$n"
    SID_VAR="SUBNET_ID_$n"
    RT_VAR="RT_ID_$n"

    if [ "${!HAS_IGW_VAR}" == "true" ] && [ "${!TYPE_VAR}" == "private" ]; then
        CANDIDATES_N[$IDX]=$n
        echo -e "  ${CYAN}[$((IDX+1))]${NC}  ${!NAME_VAR}  ${DIM}${!SID_VAR}${NC}"
        echo -e "       Route Table: ${!RT_VAR}"
        IDX=$(( IDX + 1 ))
    fi
done

if [ $IDX -eq 0 ]; then
    echo -e "  ${DIM}Keine privaten Subnetze mit IGW-Route gefunden.${NC}"
    echo ""
    echo -e "  ${YELLOW}Hinweis: Nur Subnetze vom Typ 'Private + IGW' erscheinen hier.${NC}"
    echo -e "  ${YELLOW}Public-Subnetze werden nicht angezeigt (IGW dort beabsichtigt).${NC}"
    exit 0
fi

echo ""
echo -e "  ${DIM}Mehrere moeglich: kommagetrennt, z.B. 1,2 – oder Enter fuer alle${NC}"
read -rp "  Auswahl: " SEL_INPUT
SEL_INPUT="${SEL_INPUT:-all}"

# Auswahl aufloesen
declare -a TO_REMOVE
if [ "$SEL_INPUT" == "all" ] || [ -z "$SEL_INPUT" ]; then
    for ((i=0; i<IDX; i++)); do
        TO_REMOVE[${#TO_REMOVE[@]}]=${CANDIDATES_N[$i]}
    done
else
    IFS=',' read -ra PARTS <<< "$SEL_INPUT"
    for P in "${PARTS[@]}"; do
        P=$(echo "$P" | tr -d ' \r')
        if [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le "$IDX" ]; then
            TO_REMOVE[${#TO_REMOVE[@]}]=${CANDIDATES_N[$((P-1))]}
        fi
    done
fi

if [ ${#TO_REMOVE[@]} -eq 0 ]; then
    echo -e "${RED}Keine gueltige Auswahl.${NC}"; exit 1
fi

echo ""
echo -e "${YELLOW}Folgende Subnetze werden vom IGW getrennt:${NC}"
for n in "${TO_REMOVE[@]}"; do
    NAME_VAR="SN_NAME_$n"; echo -e "  ${CYAN}${!NAME_VAR}${NC}"
done
echo ""
read -rp "Bestaetigen? [j/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0

echo ""

for n in "${TO_REMOVE[@]}"; do
    NAME_VAR="SN_NAME_$n"
    RT_VAR="RT_ID_$n"
    SID_VAR="SUBNET_ID_$n"
    RT_ID="${!RT_VAR}"
    SN_NAME="${!NAME_VAR}"
    SN_ID="${!SID_VAR}"

    echo -e "${YELLOW}${SN_NAME}:${NC}"

    if [ -z "$RT_ID" ]; then
        echo -e "  ${RED}Route Table ID nicht gefunden.${NC}"; continue
    fi

    # Route 0.0.0.0/0 loeschen
    RESULT=$(aws ec2 delete-route \
        --route-table-id "$RT_ID" \
        --destination-cidr-block 0.0.0.0/0 \
        --region "$REGION" 2>&1)

    if echo "$RESULT" | grep -qi "error\|Invalid"; then
        echo -e "  ${RED}Fehler: $RESULT${NC}"
    else
        echo -e "  ${GREEN}✓ Route 0.0.0.0/0 entfernt${NC}  (RT: $RT_ID)"
    fi

    # map-public-ip-on-launch deaktivieren
    aws ec2 modify-subnet-attribute \
        --subnet-id "$SN_ID" \
        --no-map-public-ip-on-launch \
        --region "$REGION" 2>/dev/null \
        && echo -e "  ${GREEN}✓ Automatische Public-IP deaktiviert${NC}"

    # 01_output.env aktualisieren
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^SN_HAS_IGW_${n}=.*/SN_HAS_IGW_${n}=false/" "$OUTPUT_FILE"
    else
        sed -i "s/^SN_HAS_IGW_${n}=.*/SN_HAS_IGW_${n}=false/" "$OUTPUT_FILE"
    fi
    echo -e "  ${GREEN}✓ 01_output.env aktualisiert${NC}  (SN_HAS_IGW_${n}=false)"
    echo ""
done

echo -e "${BOLD}=== Fertig ===${NC}"
echo ""
echo -e "  ${DIM}Das Subnetz hat jetzt keinen ausgehenden Internetzugang mehr.${NC}"
echo -e "  ${DIM}Bestehende SSH-Verbindungen bleiben aktiv bis sie getrennt werden.${NC}"
echo -e "  ${DIM}httpd laeuft weiter – Zugriff via LB oder Jump Host weiterhin moeglich.${NC}"
echo ""
