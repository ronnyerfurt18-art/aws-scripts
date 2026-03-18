#!/bin/bash

# SCHRITT 1: VPC, Subnetze, Internet Gateway, Routingtabellen, Security Groups
# Ausgabe der IDs wird in 01_output.env gespeichert fuer Schritt 2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/01_output.env"

# ─── Rollback-Funktion ────────────────────────────────────────────────────────
rollback() {
    local MSG="$1"
    echo ""
    echo -e "${RED}✗ FEHLER: $MSG${NC}"
    echo -e "${YELLOW}━━━ Rollback: bereits erstellte Ressourcen werden geloescht ━━━${NC}"

    # Was wurde schon erstellt?
    local CREATED=()
    [ -n "$VPC_ID" ]  && CREATED+=("VPC:  $VPC_ID")
    [ -n "$IGW_ID" ]  && CREATED+=("IGW:  $IGW_ID")
    for ((i=1; i<=SUBNET_COUNT; i++)); do
        [ -n "${SUBNET_IDS[$i]}" ] && CREATED+=("Subnetz: ${SN_NAMES[$i]} → ${SUBNET_IDS[$i]}")
        [ -n "${RT_IDS[$i]}" ]     && CREATED+=("RouteTable: rt-${SN_NAMES[$i]} → ${RT_IDS[$i]}")
        [ -n "${SG_IDS[$i]}" ]     && CREATED+=("SecGroup: sec-${SN_NAMES[$i]} → ${SG_IDS[$i]}")
    done

    if [ ${#CREATED[@]} -eq 0 ]; then
        echo -e "  ${GREEN}Nichts zu loeschen.${NC}"
        exit 1
    fi

    echo -e "  Folgende Ressourcen werden rueckgaengig gemacht:"
    for C in "${CREATED[@]}"; do
        echo -e "    ${CYAN}$C${NC}"
    done
    echo ""

    # Security Groups loeschen
    for ((i=SUBNET_COUNT; i>=1; i--)); do
        if [ -n "${SG_IDS[$i]}" ]; then
            aws ec2 delete-security-group --group-id "${SG_IDS[$i]}" --region "$REGION" 2>/dev/null \
                && echo -e "  ${GREEN}✓ SG geloescht:${NC} ${SG_IDS[$i]}" \
                || echo -e "  ${RED}✗ SG konnte nicht geloescht werden:${NC} ${SG_IDS[$i]}"
        fi
    done

    # Route Tables loeschen
    for ((i=SUBNET_COUNT; i>=1; i--)); do
        if [ -n "${RT_IDS[$i]}" ]; then
            aws ec2 delete-route-table --route-table-id "${RT_IDS[$i]}" --region "$REGION" 2>/dev/null \
                && echo -e "  ${GREEN}✓ RouteTable geloescht:${NC} ${RT_IDS[$i]}" \
                || echo -e "  ${RED}✗ RouteTable konnte nicht geloescht werden:${NC} ${RT_IDS[$i]}"
        fi
    done

    # Subnetze loeschen
    for ((i=SUBNET_COUNT; i>=1; i--)); do
        if [ -n "${SUBNET_IDS[$i]}" ]; then
            aws ec2 delete-subnet --subnet-id "${SUBNET_IDS[$i]}" --region "$REGION" 2>/dev/null \
                && echo -e "  ${GREEN}✓ Subnetz geloescht:${NC} ${SUBNET_IDS[$i]}" \
                || echo -e "  ${RED}✗ Subnetz konnte nicht geloescht werden:${NC} ${SUBNET_IDS[$i]}"
        fi
    done

    # IGW detachen und loeschen
    if [ -n "$IGW_ID" ] && [ -n "$VPC_ID" ]; then
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION" 2>/dev/null \
            && echo -e "  ${GREEN}✓ IGW geloescht:${NC} $IGW_ID" \
            || echo -e "  ${RED}✗ IGW konnte nicht geloescht werden:${NC} $IGW_ID"
    fi

    # VPC loeschen
    if [ -n "$VPC_ID" ]; then
        aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION" 2>/dev/null \
            && echo -e "  ${GREEN}✓ VPC geloescht:${NC} $VPC_ID" \
            || echo -e "  ${RED}✗ VPC konnte nicht geloescht werden:${NC} $VPC_ID"
    fi

    echo ""
    echo -e "${YELLOW}Rollback abgeschlossen. Bitte Fehler korrigieren und erneut starten.${NC}"
    exit 1
}

# ─── CIDR-Validierungsfunktion ────────────────────────────────────────────────
# Prueft: Format korrekt, Netzadresse korrekt (keine Host-Bits gesetzt),
#         CIDR liegt innerhalb des VPC-CIDRs
validate_cidr() {
    local CIDR="$1"
    local VPC="$2"

    # Format pruefen: x.x.x.x/prefix
    if ! [[ "$CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        echo -e "  ${RED}Ungültiges Format. Erwartet: x.x.x.x/prefix  (z.B. 10.16.3.0/26)${NC}"
        return 1
    fi

    local IP PREFIX
    IP=$(echo "$CIDR" | cut -d'/' -f1)
    PREFIX=$(echo "$CIDR" | cut -d'/' -f2)

    # IP-Oktette pruefen
    IFS='.' read -r A B C D <<< "$IP"
    for OCT in $A $B $C $D; do
        if (( OCT > 255 )); then
            echo -e "  ${RED}Ungültiger IP-Wert: $OCT (max. 255)${NC}"
            return 1
        fi
    done

    # Netzadresse berechnen und pruefen (Host-Bits muessen 0 sein)
    local IP_INT=$(( (A << 24) + (B << 16) + (C << 8) + D ))
    local MASK=$(( 0xFFFFFFFF << (32 - PREFIX) & 0xFFFFFFFF ))
    local NET_INT=$(( IP_INT & MASK ))

    if (( IP_INT != NET_INT )); then
        local N1=$(( (NET_INT >> 24) & 255 ))
        local N2=$(( (NET_INT >> 16) & 255 ))
        local N3=$(( (NET_INT >> 8)  & 255 ))
        local N4=$(( NET_INT & 255 ))
        echo -e "  ${RED}Keine gültige Netzadresse. Host-Bits sind gesetzt.${NC}"
        echo -e "  ${YELLOW}Meintest du: ${N1}.${N2}.${N3}.${N4}/${PREFIX} ?${NC}"
        return 1
    fi

    # Prueft ob CIDR innerhalb des VPC liegt (wenn VPC angegeben)
    if [ -n "$VPC" ]; then
        local VPC_IP VPC_PREFIX
        VPC_IP=$(echo "$VPC" | cut -d'/' -f1)
        VPC_PREFIX=$(echo "$VPC" | cut -d'/' -f2)
        IFS='.' read -r VA VB VC VD <<< "$VPC_IP"
        local VPC_INT=$(( (VA << 24) + (VB << 16) + (VC << 8) + VD ))
        local VPC_MASK=$(( 0xFFFFFFFF << (32 - VPC_PREFIX) & 0xFFFFFFFF ))
        local VPC_NET=$(( VPC_INT & VPC_MASK ))

        if (( (NET_INT & VPC_MASK) != VPC_NET )); then
            echo -e "  ${RED}CIDR $CIDR liegt nicht im VPC-Bereich $VPC${NC}"
            return 1
        fi

        if (( PREFIX < VPC_PREFIX )); then
            echo -e "  ${RED}Subnetz-Prefix /$PREFIX ist groesser als VPC-Prefix /$VPC_PREFIX${NC}"
            return 1
        fi
    fi

    return 0
}

echo -e "${BOLD}=== Schritt 1: VPC Setup ===${NC}"
echo ""

# ─── Parameter ────────────────────────────────────────────────────────────────
read -rp "AWS Region             [us-east-1]:      " REGION
REGION="${REGION:-us-east-1}"

while true; do
    read -rp "VPC CIDR               [10.16.3.0/24]:   " VPC_CIDR
    VPC_CIDR="${VPC_CIDR:-10.16.3.0/24}"
    ERR=$(validate_cidr "$VPC_CIDR" "")
    if [ $? -eq 0 ]; then break; fi
    echo -e "$ERR"
done

read -rp "VPC Name               [vpc-lab]:         " VPC_NAME
VPC_NAME="${VPC_NAME:-vpc-lab}"

read -rp "Internet Gateway Name  [igw-lab]:         " IGW_NAME
IGW_NAME="${IGW_NAME:-igw-lab}"

echo ""
while true; do
    read -rp "Anzahl Subnetze [2]: " SUBNET_COUNT
    SUBNET_COUNT="${SUBNET_COUNT:-2}"
    if [[ "$SUBNET_COUNT" =~ ^[1-9][0-9]*$ ]]; then break; fi
    echo -e "${RED}Bitte eine gueltige Zahl eingeben.${NC}"
done

# ─── Subnetz-Rechner ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Subnetz-Rechner ─────────────────────────────${NC}"

VPC_BASE=$(echo "$VPC_CIDR" | cut -d'/' -f1)
VPC_PREFIX=$(echo "$VPC_CIDR" | cut -d'/' -f2)

BITS_NEEDED=0
while (( (1 << BITS_NEEDED) < SUBNET_COUNT )); do
    ((BITS_NEEDED++))
done
SUB_PREFIX=$(( VPC_PREFIX + BITS_NEEDED ))
HOSTS_PER_SUB=$(( (1 << (32 - SUB_PREFIX)) - 2 ))

IFS='.' read -r O1 O2 O3 O4 <<< "$VPC_BASE"
BASE_INT=$(( (O1 << 24) + (O2 << 16) + (O3 << 8) + O4 ))
SUB_SIZE=$(( 1 << (32 - SUB_PREFIX) ))

echo -e "  VPC:                ${CYAN}$VPC_CIDR${NC}"
echo -e "  Subnetze:           ${CYAN}$SUBNET_COUNT${NC}"
echo -e "  Prefix pro Subnetz: ${CYAN}/$SUB_PREFIX${NC}"
echo -e "  Max. Hosts/Subnetz: ${CYAN}$HOSTS_PER_SUB${NC}"
echo ""
echo -e "  ${BOLD}Vorgeschlagene Subnetz-CIDRs:${NC}"

declare -a SUGGESTED_CIDRS
for ((s=0; s<SUBNET_COUNT; s++)); do
    SUB_INT=$(( BASE_INT + s * SUB_SIZE ))
    S1=$(( (SUB_INT >> 24) & 255 ))
    S2=$(( (SUB_INT >> 16) & 255 ))
    S3=$(( (SUB_INT >> 8)  & 255 ))
    S4=$(( SUB_INT & 255 ))
    SUGGESTED_CIDRS[$s]="${S1}.${S2}.${S3}.${S4}/${SUB_PREFIX}"
    FIRST_HOST="${S1}.${S2}.${S3}.$(( S4 + 1 ))"
    LAST_INT=$(( SUB_INT + SUB_SIZE - 2 ))
    LAST_HOST="$(( (LAST_INT >> 24) & 255 )).$(( (LAST_INT >> 16) & 255 )).$(( (LAST_INT >> 8) & 255 )).$(( LAST_INT & 255 ))"
    echo -e "    Subnetz $((s+1)): ${CYAN}${SUGGESTED_CIDRS[$s]}${NC}  (Hosts: $FIRST_HOST – $LAST_HOST, max. $HOSTS_PER_SUB)"
done

echo ""
echo -e "${BOLD}─── Subnetz-Konfiguration ───────────────────────${NC}"

declare -a SN_NAMES SN_CIDRS SN_TYPES
HAS_PUBLIC=true  # Immer true: alle Subnetze erhalten public IP, Zugriff via SG geregelt

for ((n=1; n<=SUBNET_COUNT; n++)); do
    echo ""
    echo -e "${CYAN}Subnetz $n:${NC}"
    echo -e "  ${YELLOW}Vorschlag: ${SUGGESTED_CIDRS[$((n-1))]}${NC}"

    read -rp "  Name (z.B. sub1-pub, sn-priv, web-dmz):  " SN_NAME
    [ -z "$SN_NAME" ] && echo -e "${RED}Fehler: Name darf nicht leer sein.${NC}" && exit 1

    # ─── Host-Bedarf berechnen ──────────────────────────────────────────────
    CIDR_SUGGESTION="${SUGGESTED_CIDRS[$((n-1))]}"
    read -rp "  Benoetigte Hosts [max]: " HOST_INPUT
    HOST_INPUT="${HOST_INPUT:-max}"

    if [[ "$HOST_INPUT" != "max" ]]; then
        if ! [[ "$HOST_INPUT" =~ ^[1-9][0-9]*$ ]]; then
            echo -e "  ${RED}Ungueltige Eingabe. Bitte 'max' oder eine positive Zahl eingeben.${NC}"
            exit 1
        fi
        # Kleinsten Prefix berechnen: brauche HOST_INPUT + 2 Adressen (Netz + Broadcast)
        NEEDED=$(( HOST_INPUT + 2 ))
        CALC_PREFIX=32
        while (( (1 << (32 - CALC_PREFIX)) < NEEDED )); do
            (( CALC_PREFIX-- ))
        done
        MAX_HOSTS=$(( (1 << (32 - CALC_PREFIX)) - 2 ))

        # Basis-IP aus dem Vorschlag uebernehmen, nur Prefix anpassen
        SUGGEST_BASE=$(echo "$CIDR_SUGGESTION" | cut -d'/' -f1)
        CIDR_SUGGESTION="${SUGGEST_BASE}/${CALC_PREFIX}"

        echo -e "  ${GREEN}Fuer $HOST_INPUT Hosts: /${CALC_PREFIX} (max. $MAX_HOSTS nutzbare Adressen)${NC}"
        echo -e "  ${YELLOW}Vorschlag aktualisiert: $CIDR_SUGGESTION${NC}"
    fi

    # CIDR mit Validierungsschleife + Overlap-Check
    echo -e "  ${BOLD}CIDR-Eingabe:${NC} Teilnetz des VPC ($VPC_CIDR) – kleiner als der VPC-Prefix"
    echo -e "  Vorschlag oben direkt mit Enter uebernehmen, oder eigene CIDR eingeben."
    while true; do
        read -rp "  CIDR [$CIDR_SUGGESTION]: " SN_CIDR
        SN_CIDR="${SN_CIDR:-$CIDR_SUGGESTION}"

        # Format- und Bereichs-Validierung
        VALIDATION_MSG=$(validate_cidr "$SN_CIDR" "$VPC_CIDR")
        if [ $? -ne 0 ]; then
            echo -e "$VALIDATION_MSG"
            echo -e "  ${YELLOW}Tipp: Prefix muss groesser sein als VPC (/$VPC_PREFIX), z.B. /25, /26, /27${NC}"
            continue
        fi

        # Subnetz darf nicht den ganzen VPC-Bereich umfassen
        if [ "$SN_CIDR" == "$VPC_CIDR" ]; then
            echo -e "  ${RED}Das Subnetz darf nicht genauso gross wie der VPC sein.${NC}"
            echo -e "  ${YELLOW}Vorschlag: $CIDR_SUGGESTION${NC}"
            continue
        fi

        # Overlap mit bereits definierten Subnetzen pruefen
        OVERLAP=false
        for ((prev=1; prev<n; prev++)); do
            PREV_CIDR="${SN_CIDRS[$prev]}"
            [ -z "$PREV_CIDR" ] && continue

            # IPs als Integer vergleichen
            NEW_IP=$(echo "$SN_CIDR" | cut -d'/' -f1)
            NEW_PFX=$(echo "$SN_CIDR" | cut -d'/' -f2)
            OLD_IP=$(echo "$PREV_CIDR" | cut -d'/' -f1)
            OLD_PFX=$(echo "$PREV_CIDR" | cut -d'/' -f2)

            IFS='.' read -r A B C D <<< "$NEW_IP"
            NEW_INT=$(( (A<<24)+(B<<16)+(C<<8)+D ))
            IFS='.' read -r A B C D <<< "$OLD_IP"
            OLD_INT=$(( (A<<24)+(B<<16)+(C<<8)+D ))

            # Kleinsten gemeinsamen Prefix nehmen und Netzadressen vergleichen
            MIN_PFX=$(( NEW_PFX < OLD_PFX ? NEW_PFX : OLD_PFX ))
            CMASK=$(( 0xFFFFFFFF << (32 - MIN_PFX) & 0xFFFFFFFF ))

            if (( (NEW_INT & CMASK) == (OLD_INT & CMASK) )); then
                echo -e "  ${RED}Ueberschneidung mit Subnetz $prev (${SN_NAMES[$prev]}: $PREV_CIDR)${NC}"
                echo -e "  ${YELLOW}Waehle einen anderen Adressbereich oder nutze den Vorschlag: $CIDR_SUGGESTION${NC}"
                OVERLAP=true
                break
            fi
        done
        $OVERLAP && continue

        break
    done

    echo -e "  Zugriffstyp:"
    echo -e "    [1] Public       - oeffentlich erreichbar (mit Internet Gateway)"
    echo -e "    [2] Private      - kein Zugriff von aussen, nur intern"
    echo -e "    [3] Keine        - isoliert, keine Routing-Regel, keine SG-Regel"
    read -rp "  Auswahl [1/2/3]: " SN_TYPE_SEL

    case "$SN_TYPE_SEL" in
        1) SN_TYPE="public" ;;
        2) SN_TYPE="private" ;;
        3) SN_TYPE="none" ;;
        *) SN_TYPE="private" ;;
    esac

    SN_NAMES[$n]="$SN_NAME"
    SN_CIDRS[$n]="$SN_CIDR"
    SN_TYPES[$n]="$SN_TYPE"
done

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────${NC}"
echo -e "  Region:  ${CYAN}$REGION${NC}"
echo -e "  VPC:     ${CYAN}$VPC_CIDR${NC}  ($VPC_NAME)"
echo -e "  IGW:     ${CYAN}$IGW_NAME${NC}  (wird immer angelegt – alle Instanzen erhalten public IP)"
echo ""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    case "${SN_TYPES[$n]}" in
        public)  T="${GREEN}Public${NC}" ;;
        private) T="${RED}Private${NC}" ;;
        none)    T="${YELLOW}Keine Zuweisung${NC}" ;;
    esac
    echo -e "  Subnetz $n: ${CYAN}${SN_NAMES[$n]}${NC}  ${SN_CIDRS[$n]}  → $T"
    echo -e "    Security Group: sec-${SN_NAMES[$n]}"
    echo -e "    Route Table:    rt-${SN_NAMES[$n]}"
done

echo ""
read -rp "Setup starten? [j/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${RED}Abgebrochen.${NC}" && exit 0
echo ""

# Ab hier: erstellte IDs tracken fuer Rollback
declare -a SUBNET_IDS RT_IDS SG_IDS
VPC_ID=""
IGW_ID=""

# ─── 1. VPC ───────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[1/5] VPC erstellen...${NC}"
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block "$VPC_CIDR" --region "$REGION" \
    --query "Vpc.VpcId" --output text 2>&1)

if [[ "$VPC_ID" != vpc-* ]]; then
    rollback "VPC konnte nicht erstellt werden: $VPC_ID"
fi
aws ec2 create-tags --resources "$VPC_ID" --tags Key=Name,Value="$VPC_NAME" --region "$REGION"
echo -e "  ${GREEN}✓ $VPC_NAME${NC}: $VPC_ID"

# ─── 2. Subnetze ──────────────────────────────────────────────────────────────
echo -e "${YELLOW}[2/5] Subnetze erstellen...${NC}"

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SID=$(aws ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block "${SN_CIDRS[$n]}" \
        --availability-zone "${REGION}a" \
        --region "$REGION" \
        --query "Subnet.SubnetId" --output text 2>&1)

    if [[ "$SID" == subnet-* ]]; then
        aws ec2 create-tags --resources "$SID" --tags Key=Name,Value="${SN_NAMES[$n]}" --region "$REGION"
        SUBNET_IDS[$n]="$SID"
        echo -e "  ${GREEN}✓ ${SN_NAMES[$n]}${NC}: $SID  (${SN_CIDRS[$n]})"
    else
        rollback "Subnetz '${SN_NAMES[$n]}' (${SN_CIDRS[$n]}) konnte nicht erstellt werden: $SID"
    fi
done

# ─── 3. Internet Gateway ──────────────────────────────────────────────────────
echo -e "${YELLOW}[3/5] Internet Gateway erstellen...${NC}"
IGW_ID=$(aws ec2 create-internet-gateway \
    --region "$REGION" --query "InternetGateway.InternetGatewayId" --output text 2>&1)

if [[ "$IGW_ID" != igw-* ]]; then
    rollback "Internet Gateway konnte nicht erstellt werden: $IGW_ID"
fi
aws ec2 create-tags --resources "$IGW_ID" --tags Key=Name,Value="$IGW_NAME" --region "$REGION"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
echo -e "  ${GREEN}✓ $IGW_NAME${NC}: $IGW_ID"
echo -e "  ${CYAN}Alle Subnetze erhalten public IP – Zugriff wird per Security Group geregelt.${NC}"

# ─── 4. Routingtabellen ───────────────────────────────────────────────────────
echo -e "${YELLOW}[4/5] Routingtabellen erstellen...${NC}"

for ((n=1; n<=SUBNET_COUNT; n++)); do
    RT_NAME="rt-${SN_NAMES[$n]}"
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id "$VPC_ID" --region "$REGION" \
        --query "RouteTable.RouteTableId" --output text 2>&1)

    if [[ "$RT_ID" != rtb-* ]]; then
        rollback "Route Table '$RT_NAME' konnte nicht erstellt werden: $RT_ID"
    fi
    aws ec2 create-tags --resources "$RT_ID" --tags Key=Name,Value="$RT_NAME" --region "$REGION"
    aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "${SUBNET_IDS[$n]}" --region "$REGION" > /dev/null

    # Alle Subnetze: Route zum IGW + public IP aktivieren
    aws ec2 create-route --route-table-id "$RT_ID" \
        --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION" > /dev/null
    aws ec2 modify-subnet-attribute --subnet-id "${SUBNET_IDS[$n]}" --map-public-ip-on-launch --region "$REGION"

    case "${SN_TYPES[$n]}" in
        public)  echo -e "  ${GREEN}✓ $RT_NAME${NC}: $RT_ID → IGW  |  SG: HTTP+SSH von ueberall" ;;
        private) echo -e "  ${GREEN}✓ $RT_NAME${NC}: $RT_ID → IGW  |  SG: HTTP+SSH nur aus VPC" ;;
        none)    echo -e "  ${YELLOW}✓ $RT_NAME${NC}: $RT_ID → IGW  |  SG: keine Regeln (isoliert)" ;;
    esac
    RT_IDS[$n]="$RT_ID"
done

# ─── 5. Security Groups ───────────────────────────────────────────────────────
echo -e "${YELLOW}[5/5] Security Groups erstellen...${NC}"

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SG_NAME="sec-${SN_NAMES[$n]}"

    if [ "${SN_TYPES[$n]}" == "public" ]; then
        SG_DESC="Public SG HTTP SSH allowed"
    elif [ "${SN_TYPES[$n]}" == "none" ]; then
        SG_DESC="Isolated SG no rules"
    else
        SG_DESC="Private SG internal only"
    fi

    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "$SG_DESC" \
        --vpc-id "$VPC_ID" --region "$REGION" \
        --query "GroupId" --output text 2>&1)

    if [[ "$SG_ID" == sg-* ]]; then
        if [ "${SN_TYPES[$n]}" == "public" ]; then
            aws ec2 authorize-security-group-ingress \
                --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" > /dev/null
            aws ec2 authorize-security-group-ingress \
                --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION" > /dev/null
            echo -e "  ${GREEN}✓ $SG_NAME${NC}: $SG_ID (Port 80+22 von ueberall)"
        elif [ "${SN_TYPES[$n]}" == "none" ]; then
            echo -e "  ${YELLOW}✓ $SG_NAME${NC}: $SG_ID (keine Regeln - vollstaendig isoliert)"
        else
            aws ec2 authorize-security-group-ingress \
                --group-id "$SG_ID" --protocol tcp --port 80 --cidr "$VPC_CIDR" --region "$REGION" > /dev/null
            aws ec2 authorize-security-group-ingress \
                --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$VPC_CIDR" --region "$REGION" > /dev/null
            echo -e "  ${GREEN}✓ $SG_NAME${NC}: $SG_ID (Port 80+22 nur intern $VPC_CIDR)"
        fi
        SG_IDS[$n]="$SG_ID"
    else
        rollback "Security Group '$SG_NAME' konnte nicht erstellt werden: $SG_ID"
    fi
done

# ─── Output speichern ─────────────────────────────────────────────────────────
{
    echo "REGION=$REGION"
    echo "VPC_ID=$VPC_ID"
    echo "VPC_CIDR=$VPC_CIDR"
    echo "IGW_ID=$IGW_ID"
    echo "SUBNET_COUNT=$SUBNET_COUNT"
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        echo "SN_NAME_$n=${SN_NAMES[$n]}"
        echo "SN_CIDR_$n=${SN_CIDRS[$n]}"
        echo "SN_TYPE_$n=${SN_TYPES[$n]}"
        echo "SUBNET_ID_$n=${SUBNET_IDS[$n]}"
        echo "RT_ID_$n=${RT_IDS[$n]}"
        echo "SG_ID_$n=${SG_IDS[$n]}"
    done
} > "$OUTPUT_FILE"

echo ""
echo -e "${BOLD}=== Schritt 1 abgeschlossen ===${NC}"
echo ""
echo -e "  VPC:  ${CYAN}$VPC_ID${NC}"
[ -n "$IGW_ID" ] && echo -e "  IGW:  ${CYAN}$IGW_ID${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    [ "${SN_TYPES[$n]}" == "public" ] && T="Public" || T="Private"
    echo -e "  [$T] ${SN_NAMES[$n]}: ${CYAN}${SUBNET_IDS[$n]}${NC}  sg: ${SG_IDS[$n]}"
done
echo ""
echo -e "${GREEN}IDs gespeichert in: $OUTPUT_FILE${NC}"
echo -e "${YELLOW}Weiter mit: ./02_ec2-setup.sh${NC}"
