#!/bin/bash

# SCHRITT 2: EC2 Instanzen starten
# Liest IDs aus 01_output.env
# "Hello public" / "denied" wird per User-Data beim ersten Start auf die Instanz geladen

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/01_output.env"
EC2_OUTPUT="$SCRIPT_DIR/02_output.env"

# ─── Voraussetzung prüfen ─────────────────────────────────────────────────────
if [ ! -f "$OUTPUT_FILE" ]; then
    echo -e "${RED}Fehler: 01_output.env nicht gefunden.${NC}"
    echo -e "Bitte zuerst ./01_vpc-setup.sh ausfuehren."
    exit 1
fi

source "$OUTPUT_FILE"

echo -e "${BOLD}=== Schritt 2: EC2 Instanzen ===${NC}"
echo ""
echo -e "Geladene Konfiguration aus Schritt 1:"
echo -e "  VPC:    ${CYAN}$VPC_ID${NC}  ($VPC_CIDR)"
echo -e "  Region: ${CYAN}$REGION${NC}"
echo ""

# ─── Instance Type ────────────────────────────────────────────────────────────
echo -e "${CYAN}Verfuegbare Instance Types:${NC}"
echo -e "  [1] t2.micro  – 1 vCPU,  1 GB RAM  (Free Tier / AWS Academy)"
echo -e "  [2] t2.small  – 1 vCPU,  2 GB RAM"
echo -e "  [3] t2.medium – 2 vCPU,  4 GB RAM"
echo -e "  [4] t3.micro  – 2 vCPU,  1 GB RAM  (neuere Generation)"
echo -e "  [5] t3.small  – 2 vCPU,  2 GB RAM"
echo ""
read -rp "Auswahl [1]: " IT_SEL
case "${IT_SEL:-1}" in
    1) INSTANCE_TYPE="t2.micro" ;;
    2) INSTANCE_TYPE="t2.small" ;;
    3) INSTANCE_TYPE="t2.medium" ;;
    4) INSTANCE_TYPE="t3.micro" ;;
    5) INSTANCE_TYPE="t3.small" ;;
    *)
        echo -e "${RED}Ungueltige Auswahl, verwende t2.micro.${NC}"
        INSTANCE_TYPE="t2.micro"
        ;;
esac
echo -e "  ${GREEN}Gewaehlt: $INSTANCE_TYPE${NC}"

# ─── Key Pair ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Key Pairs in AWS pruefen...${NC}"
KEY_PAIRS=$(aws ec2 describe-key-pairs \
    --query "KeyPairs[].KeyName" \
    --output text --region "$REGION" 2>/dev/null | tr '\t' '\n' | grep -v '^$')

KEY_NAME=""

if [ -n "$KEY_PAIRS" ]; then
    echo ""
    echo -e "${CYAN}Vorhandene Key Pairs:${NC}"
    i=1
    while IFS= read -r kp; do
        echo "  [$i] $kp"
        KP_LIST[$i]="$kp"
        ((i++))
    done <<< "$KEY_PAIRS"

    echo "  [$i] Neues Key Pair erstellen"
    echo ""
    read -rp "Auswahl: " KP_SEL

    if [[ "$KP_SEL" =~ ^[0-9]+$ ]] && [ "$KP_SEL" -lt "$i" ]; then
        KEY_NAME="${KP_LIST[$KP_SEL]}"
        echo -e "  ${GREEN}Verwende Key Pair: $KEY_NAME${NC}"
    else
        CREATE_NEW_KEY=true
    fi
else
    echo -e "${YELLOW}Kein Key Pair gefunden – neues wird erstellt.${NC}"
    CREATE_NEW_KEY=true
fi

if [ "${CREATE_NEW_KEY:-false}" == "true" ]; then
    echo ""
    read -rp "Name fuer neues Key Pair: " KEY_NAME
    if [ -z "$KEY_NAME" ]; then
        echo -e "${RED}Fehler: Kein Name eingegeben.${NC}"
        exit 1
    fi

    PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"
    echo -e "${YELLOW}Erstelle Key Pair '$KEY_NAME'...${NC}"

    aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --query "KeyMaterial" \
        --output text \
        --region "$REGION" > "$PEM_FILE"

    chmod 600 "$PEM_FILE"
    echo -e "  ${GREEN}Key Pair erstellt.${NC}"
    echo -e "  PEM gespeichert: ${CYAN}$PEM_FILE${NC}"
fi

# ─── AMI ermitteln ────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}AMI ermitteln (Amazon Linux 2)...${NC}"
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters \
        "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --region "$REGION" --output text)
echo -e "  AMI: ${CYAN}$AMI_ID${NC}"

# ─── Info: Wie wird Hello public / denied geladen? ────────────────────────────
echo ""
echo -e "${BOLD}Info: Wie wird der Inhalt auf die Instanz geladen?${NC}"
echo -e "  Per ${CYAN}User-Data${NC} – ein Shell-Skript das beim ersten Start automatisch"
echo -e "  ausgefuehrt wird. Es installiert Apache (httpd) und schreibt"
echo -e "  den Text in /var/www/html/index.html."
echo ""

# ─── Instanzen pro Subnetz starten ────────────────────────────────────────────
echo -e "${YELLOW}EC2 Instanzen starten...${NC}"
declare -a INSTANCE_IDS

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_NAME_VAR="SN_NAME_$n"
    SN_TYPE_VAR="SN_TYPE_$n"
    SUBNET_ID_VAR="SUBNET_ID_$n"
    SG_ID_VAR="SG_ID_$n"

    SN_NAME="${!SN_NAME_VAR}"
    SN_TYPE="${!SN_TYPE_VAR}"
    SUBNET_ID="${!SUBNET_ID_VAR}"
    SG_ID="${!SG_ID_VAR}"

    if [ "$SN_TYPE" == "public" ]; then
        DEFAULT_TEXT="Hello public"
    else
        DEFAULT_TEXT="Hallo, ich bin eine private Instanz"
    fi
    read -rp "  HTTP-Antworttext fuer ec2-${SN_NAME} [$DEFAULT_TEXT]: " RESPONSE_TEXT
    RESPONSE_TEXT="${RESPONSE_TEXT:-$DEFAULT_TEXT}"

    USER_DATA="#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd
echo '<h1>$RESPONSE_TEXT</h1>' > /var/www/html/index.html"

    echo ""
    echo -e "  Starte ec2-${SN_NAME} in ${SN_TYPE} Subnetz..."
    echo -e "  Subnetz: $SUBNET_ID  |  SG: $SG_ID"
    echo -e "  Antwort: \"$RESPONSE_TEXT\" (per User-Data)"

    IID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --subnet-id "$SUBNET_ID" \
        --security-group-ids "$SG_ID" \
        --key-name "$KEY_NAME" \
        --user-data "$USER_DATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ec2-${SN_NAME}}]" \
        --region "$REGION" \
        --query "Instances[0].InstanceId" --output text 2>&1)

    if [[ "$IID" == i-* ]]; then
        INSTANCE_IDS[$n]="$IID"
        echo -e "  ${GREEN}ec2-${SN_NAME}${NC}: $IID"
    else
        echo -e "  ${RED}Fehler beim Starten ec2-${SN_NAME}: $IID${NC}"
        exit 1
    fi
done

# ─── Output speichern ─────────────────────────────────────────────────────────
{
    echo "REGION=$REGION"
    echo "SUBNET_COUNT=$SUBNET_COUNT"
    echo "KEY_NAME=$KEY_NAME"
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        SN_NAME_VAR="SN_NAME_$n"
        SN_TYPE_VAR="SN_TYPE_$n"
        echo "SN_NAME_$n=${!SN_NAME_VAR}"
        echo "SN_TYPE_$n=${!SN_TYPE_VAR}"
        echo "INSTANCE_ID_$n=${INSTANCE_IDS[$n]}"
    done
} > "$EC2_OUTPUT"

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Schritt 2 abgeschlossen ===${NC}"
echo ""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_NAME_VAR="SN_NAME_$n"
    SN_TYPE_VAR="SN_TYPE_$n"
    echo -e "  ec2-${!SN_NAME_VAR}: ${CYAN}${INSTANCE_IDS[$n]}${NC}  [${!SN_TYPE_VAR}]"
done

echo ""
echo -e "  Key Pair: ${CYAN}$KEY_NAME${NC}"
PEM_PATH="$SCRIPT_DIR/${KEY_NAME}.pem"
[ -f "$PEM_PATH" ] && echo -e "  PEM-Datei: ${CYAN}$PEM_PATH${NC}"

# ─── Public Instanz und Private IP ermitteln ──────────────────────────────────
PUBLIC_INSTANCE_ID=""
PUBLIC_SN_NAME=""
PRIVATE_IP_TARGET=""

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_TYPE_VAR="SN_TYPE_$n"
    SN_NAME_VAR="SN_NAME_$n"
    if [ "${!SN_TYPE_VAR}" == "public" ] && [ -z "$PUBLIC_INSTANCE_ID" ]; then
        PUBLIC_INSTANCE_ID="${INSTANCE_IDS[$n]}"
        PUBLIC_SN_NAME="${!SN_NAME_VAR}"
    elif [ "${!SN_TYPE_VAR}" == "private" ] && [ -z "$PRIVATE_IP_TARGET" ]; then
        PRIVATE_IP_TARGET="${INSTANCE_IDS[$n]}"  # wird spaeter aufgeloest
    fi
done

# ─── Auf running warten und IPs holen ────────────────────────────────────────
if [ -n "$PUBLIC_INSTANCE_ID" ] && [ -f "$PEM_PATH" ]; then
    echo ""
    echo -e "${YELLOW}Warte auf Public Instanz (ec2-${PUBLIC_SN_NAME})...${NC}"
    for ((i=1; i<=24; i++)); do
        RESULT=$(aws ec2 describe-instances --instance-ids "$PUBLIC_INSTANCE_ID" \
            --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress]" \
            --output text --region "$REGION" 2>/dev/null)
        STATE=$(echo "$RESULT" | awk '{print $1}')
        PUB_IP=$(echo "$RESULT" | awk '{print $2}')
        PRIV_IP_PUB=$(echo "$RESULT" | awk '{print $3}')
        [ "$PUB_IP" == "None" ] && PUB_IP=""
        if [ "$STATE" == "running" ] && [ -n "$PUB_IP" ]; then
            echo -e "  ${GREEN}✓ Bereit:${NC} $PUB_IP"
            break
        fi
        echo -e "  ${DIM}[$i/24] $STATE – warte 15s...${NC}"
        sleep 15
    done

    # Private IP der privaten Instanz holen
    if [ -n "$PRIVATE_IP_TARGET" ]; then
        PRIV_IP_TARGET=$(aws ec2 describe-instances --instance-ids "$PRIVATE_IP_TARGET" \
            --query "Reservations[0].Instances[0].PrivateIpAddress" \
            --output text --region "$REGION" 2>/dev/null)
        [ "$PRIV_IP_TARGET" == "None" ] && PRIV_IP_TARGET=""
    fi

    # ─── PEM auf Public Instanz kopieren ─────────────────────────────────────
    if [ -n "$PUB_IP" ]; then
        echo ""
        echo -e "${YELLOW}Kopiere PEM auf Public Instanz...${NC}"
        scp -i "$PEM_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "$PEM_PATH" "ec2-user@${PUB_IP}:~/${KEY_NAME}.pem" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ ${KEY_NAME}.pem auf ec2-user@${PUB_IP}:~/ kopiert${NC}"
            # Berechtigungen setzen
            ssh -i "$PEM_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                "ec2-user@${PUB_IP}" "chmod 400 ~/${KEY_NAME}.pem" 2>/dev/null
        else
            echo -e "  ${RED}✗ SCP fehlgeschlagen – manuell kopieren:${NC}"
            echo -e "  ${CYAN}scp -i $PEM_PATH $PEM_PATH ec2-user@${PUB_IP}:~/${NC}"
        fi

        # ─── Verbindungsbefehle ausgeben ──────────────────────────────────────
        echo ""
        echo -e "${BOLD}─── Verbindungsbefehle ──────────────────────────────${NC}"
        echo -e "  SSH direkt:"
        echo -e "  ${CYAN}ssh -i $PEM_PATH ec2-user@${PUB_IP}${NC}"
        if [ -n "$PRIV_IP_TARGET" ]; then
            echo ""
            echo -e "  SSH-Tunnel (Public → Private, Port 4747):"
            echo -e "  ${CYAN}ssh -i ${KEY_NAME}.pem -L 0.0.0.0:4747:${PRIV_IP_TARGET}:22 ec2-user@${PUB_IP} -N${NC}"
            echo ""
            echo -e "  Dann von Public auf Private springen:"
            echo -e "  ${CYAN}ssh -i ${KEY_NAME}.pem -p 4747 ec2-user@localhost${NC}"
        fi
    fi
else
    echo ""
    echo -e "${YELLOW}Warte ca. 2 Minuten bis die Instanzen gestartet sind.${NC}"
    echo ""
    echo -e "SSH-Zugriff auf Public Instanz:"
    echo -e "${CYAN}ssh -i $PEM_PATH ec2-user@<PUBLIC_IP>${NC}"
fi
