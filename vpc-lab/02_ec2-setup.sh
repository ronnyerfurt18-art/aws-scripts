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
[ -f "$SCRIPT_DIR/${KEY_NAME}.pem" ] && echo -e "  PEM-Datei: ${CYAN}$SCRIPT_DIR/${KEY_NAME}.pem${NC}"
echo ""
echo -e "${YELLOW}Warte ca. 2 Minuten bis die Instanzen gestartet sind.${NC}"
echo -e "${YELLOW}Dann Public IPs abrufen mit:${NC}"
echo -e "${CYAN}./03_get-ips.sh${NC}"
echo ""
echo -e "SSH-Zugriff auf Public Instanz:"
echo -e "${CYAN}ssh -i $SCRIPT_DIR/${KEY_NAME}.pem ec2-user@<PUBLIC_IP>${NC}"
