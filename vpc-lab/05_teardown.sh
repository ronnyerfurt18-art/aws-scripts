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

[ -f "$OUTPUT_01" ] && source "$OUTPUT_01"
[ -f "$OUTPUT_02" ] && source "$OUTPUT_02"
[ -z "$REGION" ] && REGION="us-east-1"

# ─── Fallback: VPC aus AWS waehlen wenn .env leer ────────────────────────────
if ! grep -q "VPC_ID=vpc-" "$OUTPUT_01" 2>/dev/null; then
    echo -e "${YELLOW}01_output.env leer – VPCs in Region $REGION werden abgefragt...${NC}"
    echo ""

    VPC_RAW=$(aws ec2 describe-vpcs \
        --query "Vpcs[].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$VPC_RAW" ]; then
        echo -e "${RED}Keine VPCs in $REGION gefunden.${NC}"; exit 1
    fi

    declare -a VPC_IDS VPC_CIDRS VPC_NAMES
    IDX=0
    while IFS=$'\t' read -r VID VCIDR VNAME; do
        [ "$VNAME" == "None" ] && VNAME="-"
        VPC_IDS[$IDX]="$VID"
        VPC_CIDRS[$IDX]="$VCIDR"
        VPC_NAMES[$IDX]="$VNAME"
        echo -e "  ${CYAN}[$((IDX+1))]${NC}  $VID  $VCIDR  ${DIM}$VNAME${NC}"
        (( IDX++ ))
    done <<< "$VPC_RAW"

    echo ""
    read -rp "VPC fuer Teardown auswaehlen [1-$IDX]: " VPC_SEL
    if ! [[ "$VPC_SEL" =~ ^[0-9]+$ ]] || [ "$VPC_SEL" -lt 1 ] || [ "$VPC_SEL" -gt "$IDX" ]; then
        echo -e "${RED}Ungueltige Auswahl.${NC}"; exit 1
    fi
    VPC_ID="${VPC_IDS[$((VPC_SEL-1))]}"
    VPC_CIDR="${VPC_CIDRS[$((VPC_SEL-1))]}"

    # Ressourcen des gewaehlten VPC aus AWS laden
    SUBNET_COUNT=0
    while IFS=$'\t' read -r SID SCIDR SNAME; do
        (( SUBNET_COUNT++ ))
        eval "SUBNET_ID_$SUBNET_COUNT=$SID"
        eval "SN_CIDR_$SUBNET_COUNT=$SCIDR"
        [ "$SNAME" == "None" ] && SNAME="subnet-$SUBNET_COUNT"
        eval "SN_NAME_$SUBNET_COUNT=$SNAME"
    done < <(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "Subnets[].[SubnetId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
        --output text --region "$REGION" 2>/dev/null)

    while IFS=$'\t' read -r RTID RTNAME; do
        [ "$RTNAME" == "None" ] && RTNAME=""
        for ((n=1; n<=SUBNET_COUNT; n++)); do
            SNAME_VAR="SN_NAME_$n"
            if [ "$RTNAME" == "rt-${!SNAME_VAR}" ]; then
                eval "RT_ID_$n=$RTID"
                break
            fi
        done
    done < <(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=false" \
        --query "RouteTables[].[RouteTableId,Tags[?Key=='Name']|[0].Value]" \
        --output text --region "$REGION" 2>/dev/null)

    for ((n=1; n<=SUBNET_COUNT; n++)); do
        SNAME_VAR="SN_NAME_$n"
        SGID=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sec-${!SNAME_VAR}" \
            --query "SecurityGroups[0].GroupId" \
            --output text --region "$REGION" 2>/dev/null)
        [ "$SGID" != "None" ] && eval "SG_ID_$n=$SGID"
    done

    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query "InternetGateways[0].InternetGatewayId" \
        --output text --region "$REGION" 2>/dev/null)
    [ "$IGW_ID" == "None" ] && IGW_ID=""

    # EC2-Instanzen im VPC laden (pro Subnetz)
    for ((n=1; n<=SUBNET_COUNT; n++)); do
        SID_VAR="SUBNET_ID_$n"
        IID=$(aws ec2 describe-instances \
            --filters "Name=subnet-id,Values=${!SID_VAR}" \
                      "Name=instance-state-name,Values=running,stopped,pending,stopping" \
            --query "Reservations[0].Instances[0].InstanceId" \
            --output text --region "$REGION" 2>/dev/null)
        [ "$IID" != "None" ] && [ -n "$IID" ] && eval "INSTANCE_ID_$n=$IID"
    done

    echo ""
fi

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

# Custom ACLs
echo ""
if $VPC_EXISTS; then
    CUSTOM_ACLS=$(aws ec2 describe-network-acls \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=false" \
        --query "NetworkAcls[].NetworkAclId" \
        --output text --region "$REGION" 2>/dev/null | tr '\t' ' ')
    if [ -n "$CUSTOM_ACLS" ]; then
        echo -e "  [8] ACL  Benutzerdefinierte ACLs loeschen:"
        for AID in $CUSTOM_ACLS; do
            echo -e "       ${CYAN}$AID${NC}"
        done
    else
        echo -e "  ${DIM}[8] ACL  – keine benutzerdefinierten ACLs (nur Standard)${NC}"
    fi
else
    echo -e "  ${DIM}[8] ACL  – VPC nicht mehr vorhanden${NC}"
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
    SEL_SET="1 2 3 4 5 6 7 8"
else
    SEL_SET=""
    IFS=',' read -ra PARTS <<< "$RAW_SEL"
    for P in "${PARTS[@]}"; do
        P=$(echo "$P" | tr -d ' \r')
        [[ "$P" =~ ^[1-8]$ ]] && SEL_SET="$SEL_SET $P"
    done
    if [ -z "$SEL_SET" ]; then
        echo -e "${RED}Keine gueltige Auswahl.${NC}"; exit 1
    fi
fi

# Abhaengigkeiten automatisch ergaenzen:
# Subnetz [3] benoetigt SG [2] vorher
# VPC [6] benoetigt SG [2], SN [3], RT [4], IGW [5] vorher
[[ "$SEL_SET" == *" 3"* || "$SEL_SET" == *"3 "* || "$SEL_SET" =~ ^3$ ]] && SEL_SET="$SEL_SET 2"
[[ "$SEL_SET" == *" 6"* || "$SEL_SET" == *"6 "* || "$SEL_SET" =~ ^6$ ]] && SEL_SET="$SEL_SET 2 3 4 5"

# Duplikate entfernen, in fester Reihenfolge 1-8 sortieren (Bash 3.2 kompatibel)
STEPS=()
for S in 1 2 3 4 5 6 7 8; do
    [[ " $SEL_SET " == *" $S "* ]] && STEPS[${#STEPS[@]}]="$S"
done

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
        8) echo -e "  ${RED}✗${NC} Benutzerdefinierte ACLs loeschen" ;;
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

# ─── 8. Benutzerdefinierte ACLs loeschen ─────────────────────────────────────
if has_step 8; then
    echo -e "${YELLOW}[8] Benutzerdefinierte ACLs loeschen...${NC}"
    CUSTOM_ACLS=$(aws ec2 describe-network-acls \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=false" \
        --query "NetworkAcls[].NetworkAclId" \
        --output text --region "$REGION" 2>/dev/null | tr '\t' ' ')

    if [ -z "$CUSTOM_ACLS" ]; then
        echo -e "  ${DIM}Keine benutzerdefinierten ACLs gefunden.${NC}"
    else
        # Standard-ACL des VPC ermitteln (fuer Reassoziation)
        DEFAULT_ACL=$(aws ec2 describe-network-acls \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=default,Values=true" \
            --query "NetworkAcls[0].NetworkAclId" \
            --output text --region "$REGION" 2>/dev/null)

        for AID in $CUSTOM_ACLS; do
            # Zugeordnete Subnetze zuerst zur Standard-ACL verschieben
            ASSOC_IDS=$(aws ec2 describe-network-acls --network-acl-ids "$AID" \
                --query "NetworkAcls[0].Associations[].NetworkAclAssociationId" \
                --output text --region "$REGION" 2>/dev/null | tr '\t' ' ')

            for ASSOC_ID in $ASSOC_IDS; do
                [ -z "$ASSOC_ID" ] || [ "$ASSOC_ID" == "None" ] && continue
                aws ec2 replace-network-acl-association \
                    --association-id "$ASSOC_ID" \
                    --network-acl-id "$DEFAULT_ACL" \
                    --region "$REGION" > /dev/null 2>&1
            done

            RESULT=$(aws ec2 delete-network-acl --network-acl-id "$AID" --region "$REGION" 2>&1)
            classify_result "$RESULT"
            case $? in
                0) echo -e "  ${GREEN}✓ ACL${NC}: $AID geloescht" ;;
                1) echo -e "  ${DIM}  ACL: $AID  [bereits geloescht]${NC}" ;;
                2) echo -e "  ${RED}  Fehler ACL $AID: $RESULT${NC}" ;;
            esac
        done
    fi
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
