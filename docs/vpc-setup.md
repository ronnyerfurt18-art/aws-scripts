# vpc-setup – Fallback Anleitung

## Voraussetzungen

- Gültige AWS Credentials
- IAM-Rechte: `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:CreateInternetGateway`, `ec2:AttachInternetGateway`, `ec2:CreateRouteTable`, `ec2:CreateRoute`, `ec2:AssociateRouteTable`, `ec2:CreateSecurityGroup`, `ec2:AuthorizeSecurityGroupIngress`, `ec2:RunInstances`, `ec2:DescribeImages`

## Manuelle Schritte (ohne Skript)

### Schritt 1: VPC erstellen

```bash
REGION="us-east-1"
VPC_CIDR="10.16.3.0/24"

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --region "$REGION" \
  --query "Vpc.VpcId" --output text)

aws ec2 create-tags --resources "$VPC_ID" \
  --tags Key=Name,Value="vpc-lab" --region "$REGION"

echo "VPC erstellt: $VPC_ID"
```

### Schritt 2: Subnetze erstellen

```bash
# Public Subnetz
SUBNET_PUBLIC=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.16.3.0/25" \
  --availability-zone "${REGION}a" \
  --region "$REGION" \
  --query "Subnet.SubnetId" --output text)

aws ec2 create-tags --resources "$SUBNET_PUBLIC" \
  --tags Key=Name,Value="subnet-public" --region "$REGION"

# Private Subnetz
SUBNET_PRIVATE=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.16.3.128/25" \
  --availability-zone "${REGION}a" \
  --region "$REGION" \
  --query "Subnet.SubnetId" --output text)

aws ec2 create-tags --resources "$SUBNET_PRIVATE" \
  --tags Key=Name,Value="subnet-private" --region "$REGION"
```

### Schritt 3: Internet Gateway erstellen und anhängen

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --query "InternetGateway.InternetGatewayId" --output text)

aws ec2 create-tags --resources "$IGW_ID" \
  --tags Key=Name,Value="igw-lab" --region "$REGION"

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" --region "$REGION"

echo "IGW: $IGW_ID"
```

### Schritt 4: Routingtabellen erstellen

```bash
# Routingtabelle für Public Subnetz
RT_PUBLIC=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" --region "$REGION" \
  --query "RouteTable.RouteTableId" --output text)

aws ec2 create-tags --resources "$RT_PUBLIC" \
  --tags Key=Name,Value="rt-public" --region "$REGION"

# Route zum Internet Gateway hinzufügen
aws ec2 create-route \
  --route-table-id "$RT_PUBLIC" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" --region "$REGION"

# Route Table mit Public Subnetz verknüpfen
aws ec2 associate-route-table \
  --route-table-id "$RT_PUBLIC" \
  --subnet-id "$SUBNET_PUBLIC" --region "$REGION"

# Öffentliche IP automatisch zuweisen
aws ec2 modify-subnet-attribute \
  --subnet-id "$SUBNET_PUBLIC" \
  --map-public-ip-on-launch --region "$REGION"
```

### Schritt 5: Security Groups erstellen

```bash
# Security Group für Public Subnetz (HTTP + SSH)
SG_PUBLIC=$(aws ec2 create-security-group \
  --group-name "sec-public" \
  --description "SG für Public Subnetz" \
  --vpc-id "$VPC_ID" --region "$REGION" \
  --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PUBLIC" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PUBLIC" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$REGION"

# Security Group für Private Subnetz (nur intern)
SG_PRIVATE=$(aws ec2 create-security-group \
  --group-name "sec-private" \
  --description "SG für Private Subnetz" \
  --vpc-id "$VPC_ID" --region "$REGION" \
  --query "GroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_PRIVATE" --protocol tcp --port 80 --cidr "$VPC_CIDR" --region "$REGION"
```

### Schritt 6: Aktuelles AMI ermitteln

```bash
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
    "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --region "$REGION" --output text)

echo "AMI: $AMI_ID"
```

### Schritt 7: EC2-Instanzen starten

```bash
# Public EC2 mit Apache Webserver
aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "t2.micro" \
  --subnet-id "$SUBNET_PUBLIC" \
  --security-group-ids "$SG_PUBLIC" \
  --user-data '#!/bin/bash
yum update -y && yum install -y httpd
systemctl start httpd && systemctl enable httpd
echo "<h1>Hello public</h1>" > /var/www/html/index.html' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ec2-public}]' \
  --region "$REGION"
```

### Schritt 8: Öffentliche IP abrufen (nach ~2 Minuten)

```bash
INSTANCE_ID="i-xxxxxxxxxxxxxxxxx"  # aus Schritt 7 entnehmen

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text --region "$REGION"
```

## Erwartete Ausgabe

Nach Schritt 8 erscheint eine öffentliche IP-Adresse. Im Browser aufgerufen zeigt die Public EC2 `Hello public`.

## Häufige Fehler & Lösungen

| Fehler | Ursache | Lösung |
|--------|---------|--------|
| `InvalidSubnet.Conflict` | CIDR-Bereich überlappt | Anderen CIDR-Block wählen (z.B. `10.16.3.0/25`) |
| `VpcLimitExceeded` | Max. 5 VPCs im Account | Alte VPCs löschen |
| `InvalidAMIID` | AMI nicht in Region verfügbar | Schritt 6 erneut für die richtige Region ausführen |
| Keine öffentliche IP | Auto-Assign nicht aktiv | Schritt 4 (`modify-subnet-attribute`) wiederholen |

## Rollback / Aufräumen

```bash
# Reihenfolge beim Löschen beachten!

# 1. EC2-Instanzen beenden
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"

# 2. Internet Gateway trennen und löschen
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION"

# 3. Subnetze löschen
aws ec2 delete-subnet --subnet-id "$SUBNET_PUBLIC" --region "$REGION"
aws ec2 delete-subnet --subnet-id "$SUBNET_PRIVATE" --region "$REGION"

# 4. Routingtabellen löschen
aws ec2 delete-route-table --route-table-id "$RT_PUBLIC" --region "$REGION"

# 5. Security Groups löschen
aws ec2 delete-security-group --group-id "$SG_PUBLIC" --region "$REGION"
aws ec2 delete-security-group --group-id "$SG_PRIVATE" --region "$REGION"

# 6. VPC löschen
aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
```

## Abhängigkeiten zu anderen Modulen

- Vorher: `aws-credentials-update.sh` – Credentials müssen gültig sein
- Nachher: Skripte im `vpc-lab/`-Unterordner bauen auf dieser Infrastruktur auf (starten mit `./vpc-lab/menu.sh`)
