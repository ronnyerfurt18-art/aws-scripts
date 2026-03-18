#!/bin/bash

# VPC Setup – dynamische Subnetz-Konfiguration
# Beliebig viele Subnetze, jeweils Public oder Private

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}=== VPC Setup – Parametereingabe ===${NC}"
echo ""

# ─── Allgemeine Parameter ─────────────────────────────────────────────────────
read -rp "AWS Region             [us-east-1]:      " REGION
REGION="${REGION:-us-east-1}"

read -rp "VPC CIDR               [10.16.3.0/24]:   " VPC_CIDR
VPC_CIDR="${VPC_CIDR:-10.16.3.0/24}"

read -rp "VPC Name               [vpc-lab]:         " VPC_NAME
VPC_NAME="${VPC_NAME:-vpc-lab}"

read -rp "Internet Gateway Name  [igw-lab]:         " IGW_NAME
IGW_NAME="${IGW_NAME:-igw-lab}"

read -rp "EC2 Instance Type      [t2.micro]:        " INSTANCE_TYPE
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"

# ─── Anzahl Subnetze ──────────────────────────────────────────────────────────
echo ""
while true; do
    read -rp "Anzahl Subnetze [2]: " SUBNET_COUNT
    SUBNET_COUNT="${SUBNET_COUNT:-2}"
    if [[ "$SUBNET_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        break
    fi
    echo -e "${RED}Bitte eine gültige Zahl eingeben.${NC}"
done

# ─── Subnetze konfigurieren ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Subnetz-Konfiguration ───────────────────────${NC}"

declare -a SN_NAMES SN_CIDRS SN_TYPES
HAS_PUBLIC=false

for ((n=1; n<=SUBNET_COUNT; n++)); do
    echo ""
    echo -e "${CYAN}Subnetz $n:${NC}"

    read -rp "  Name:  " SN_NAME
    if [ -z "$SN_NAME" ]; then
        echo -e "${RED}Fehler: Name darf nicht leer sein.${NC}"
        exit 1
    fi

    read -rp "  CIDR (muss in $VPC_CIDR liegen, z.B. 10.17.3.0/25): " SN_CIDR
    if [ -z "$SN_CIDR" ]; then
        echo -e "${RED}Fehler: CIDR darf nicht leer sein.${NC}"
        exit 1
    fi

    echo -e "  Zugriffstyp:"
    echo -e "    [1] Public  – öffentlich erreichbar (mit Internet Gateway)"
    echo -e "    [2] Private – kein Zugriff von außen"
    read -rp "  Auswahl [1/2]: " SN_TYPE_SEL

    case "$SN_TYPE_SEL" in
        1) SN_TYPE="public"; HAS_PUBLIC=true ;;
        2) SN_TYPE="private" ;;
        *) echo -e "${RED}Ungültige Auswahl, setze auf Private.${NC}"; SN_TYPE="private" ;;
    esac

    SN_NAMES[$n]="$SN_NAME"
    SN_CIDRS[$n]="$SN_CIDR"
    SN_TYPES[$n]="$SN_TYPE"
done

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────${NC}"
echo -e "  Region:            ${CYAN}$REGION${NC}"
echo -e "  VPC:               ${CYAN}$VPC_CIDR${NC}  ($VPC_NAME)"
echo -e "  Internet Gateway:  ${CYAN}$IGW_NAME${NC}  ($( $HAS_PUBLIC && echo 'wird angelegt' || echo 'wird NICHT benötigt'))"
echo -e "  Instance Type:     ${CYAN}$INSTANCE_TYPE${NC}"
echo ""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    TYPE_LABEL=$( [ "${SN_TYPES[$n]}" == "public" ] && echo -e "${GREEN}Public${NC}" || echo -e "${RED}Private${NC}" )
    echo -e "  Subnetz $n: ${CYAN}${SN_NAMES[$n]}${NC}  ${SN_CIDRS[$n]}  → $TYPE_LABEL"
    echo -e "    Route Table: rt-${SN_NAMES[$n]}"
done

echo ""
read -rp "Setup starten? [j/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[JjYy]$ ]]; then
    echo -e "${RED}Abgebrochen.${NC}"
    exit 0
fi

echo ""

# ─── 1. VPC ───────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[1] VPC erstellen...${NC}"
VPC_ID=$(aws ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --region "$REGION" \
    --query "Vpc.VpcId" --output text)

aws ec2 create-tags --resources "$VPC_ID" \
    --tags Key=Name,Value="$VPC_NAME" --region "$REGION"

echo -e "  ${GREEN}$VPC_NAME${NC}: $VPC_ID"

# ─── 2. Subnetze anlegen ──────────────────────────────────────────────────────
echo -e "${YELLOW}[2] Subnetze erstellen...${NC}"
declare -a SUBNET_IDS

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SID=$(aws ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block "${SN_CIDRS[$n]}" \
        --availability-zone "${REGION}a" \
        --region "$REGION" \
        --query "Subnet.SubnetId" --output text 2>&1)

    if [[ "$SID" == subnet-* ]]; then
        aws ec2 create-tags --resources "$SID" \
            --tags Key=Name,Value="${SN_NAMES[$n]}" --region "$REGION"
        SUBNET_IDS[$n]="$SID"
        echo -e "  ${GREEN}${SN_NAMES[$n]}${NC}: $SID  (${SN_CIDRS[$n]})"
    else
        echo -e "  ${RED}Fehler bei Subnetz ${SN_NAMES[$n]}: $SID${NC}"
        echo -e "  ${RED}Tipp: CIDR muss innerhalb von $VPC_CIDR liegen (z.B. 10.17.3.0/25 oder 10.17.3.128/25)${NC}"
        exit 1
    fi
done

# ─── 3. Internet Gateway (nur wenn Public-Subnetz vorhanden) ──────────────────
IGW_ID=""
if $HAS_PUBLIC; then
    echo -e "${YELLOW}[3] Internet Gateway erstellen und anhängen...${NC}"
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$REGION" \
        --query "InternetGateway.InternetGatewayId" --output text)

    aws ec2 create-tags --resources "$IGW_ID" \
        --tags Key=Name,Value="$IGW_NAME" --region "$REGION"

    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID" --region "$REGION"

    echo -e "  ${GREEN}$IGW_NAME${NC}: $IGW_ID → angehängt an $VPC_ID"
else
    echo -e "${YELLOW}[3] Kein Internet Gateway benötigt (keine Public Subnetze).${NC}"
fi

# ─── 4. Routingtabellen ───────────────────────────────────────────────────────
echo -e "${YELLOW}[4] Routingtabellen erstellen...${NC}"
declare -a RT_IDS

for ((n=1; n<=SUBNET_COUNT; n++)); do
    RT_NAME="rt-${SN_NAMES[$n]}"
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query "RouteTable.RouteTableId" --output text)

    aws ec2 create-tags --resources "$RT_ID" \
        --tags Key=Name,Value="$RT_NAME" --region "$REGION"

    aws ec2 associate-route-table \
        --route-table-id "$RT_ID" \
        --subnet-id "${SUBNET_IDS[$n]}" \
        --region "$REGION" > /dev/null

    if [ "${SN_TYPES[$n]}" == "public" ] && [ -n "$IGW_ID" ]; then
        aws ec2 create-route \
            --route-table-id "$RT_ID" \
            --destination-cidr-block 0.0.0.0/0 \
            --gateway-id "$IGW_ID" \
            --region "$REGION" > /dev/null
        echo -e "  ${GREEN}$RT_NAME${NC}: $RT_ID → 0.0.0.0/0 via IGW"

        aws ec2 modify-subnet-attribute \
            --subnet-id "${SUBNET_IDS[$n]}" \
            --map-public-ip-on-launch --region "$REGION"
    else
        echo -e "  ${GREEN}$RT_NAME${NC}: $RT_ID → nur lokaler Traffic"
    fi

    RT_IDS[$n]="$RT_ID"
done

# ─── 5. Security Groups ───────────────────────────────────────────────────────
echo -e "${YELLOW}[5] Security Groups erstellen...${NC}"
declare -a SG_IDS

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SG_NAME="sec-${SN_NAMES[$n]}"
    SG_ID=$(aws ec2 create-security-group \
        --group-name "$SG_NAME" \
        --description "SG für ${SN_NAMES[$n]}" \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query "GroupId" --output text)

    if [ "${SN_TYPES[$n]}" == "public" ]; then
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 \
            --region "$REGION" > /dev/null
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 \
            --region "$REGION" > /dev/null
        echo -e "  ${GREEN}$SG_NAME${NC}: $SG_ID (Port 80 + 22 von 0.0.0.0/0)"
    else
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" --protocol tcp --port 80 --cidr "$VPC_CIDR" \
            --region "$REGION" > /dev/null
        echo -e "  ${GREEN}$SG_NAME${NC}: $SG_ID (Port 80 nur aus $VPC_CIDR)"
    fi

    SG_IDS[$n]="$SG_ID"
done

# ─── 6. AMI ermitteln ─────────────────────────────────────────────────────────
echo -e "${YELLOW}[6] Aktuelles Amazon Linux 2 AMI ermitteln...${NC}"
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters \
        "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
        "Name=state,Values=available" \
    --query "sort_by(Images, &CreationDate)[-1].ImageId" \
    --region "$REGION" --output text)

echo -e "  AMI: ${CYAN}$AMI_ID${NC}"

# ─── 7. EC2 Instanzen ─────────────────────────────────────────────────────────
echo -e "${YELLOW}[7] EC2 Instanzen starten...${NC}"
declare -a INSTANCE_IDS

for ((n=1; n<=SUBNET_COUNT; n++)); do
    if [ "${SN_TYPES[$n]}" == "public" ]; then
        RESPONSE_TEXT="Hello public"
    else
        RESPONSE_TEXT="denied"
    fi

    USER_DATA="#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd
echo '<h1>${RESPONSE_TEXT}</h1>' > /var/www/html/index.html"

    IID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --subnet-id "${SUBNET_IDS[$n]}" \
        --security-group-ids "${SG_IDS[$n]}" \
        --user-data "$USER_DATA" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ec2-${SN_NAMES[$n]}}]" \
        --region "$REGION" \
        --query "Instances[0].InstanceId" --output text)

    INSTANCE_IDS[$n]="$IID"
    echo -e "  ${GREEN}ec2-${SN_NAMES[$n]}${NC}: $IID → \"$RESPONSE_TEXT\""
done

# ─── Abschlusszusammenfassung ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Setup abgeschlossen ===${NC}"
echo ""
echo -e "  VPC ($VPC_NAME): ${CYAN}$VPC_ID${NC}"
[ -n "$IGW_ID" ] && echo -e "  IGW ($IGW_NAME): ${CYAN}$IGW_ID${NC}"
echo ""
for ((n=1; n<=SUBNET_COUNT; n++)); do
    TYPE_LABEL=$( [ "${SN_TYPES[$n]}" == "public" ] && echo "Public" || echo "Private" )
    echo -e "  [$TYPE_LABEL] ${SN_NAMES[$n]}: ${CYAN}${SUBNET_IDS[$n]}${NC}  rt: ${RT_IDS[$n]}  ec2: ${INSTANCE_IDS[$n]}"
done

echo ""
echo -e "${YELLOW}Public IPs nach ~2 Minuten abrufen:${NC}"
for ((n=1; n<=SUBNET_COUNT; n++)); do
    if [ "${SN_TYPES[$n]}" == "public" ]; then
        echo -e "${CYAN}aws ec2 describe-instances --instance-ids ${INSTANCE_IDS[$n]} --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $REGION${NC}"
    fi
done
