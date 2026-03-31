#!/bin/bash

# Load Balancer verwalten (ALB)
# Erstellen, anzeigen, loeschen

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/config.env" ] && source "$SCRIPT_DIR/config.env"
[ -z "$REGION" ] && REGION="us-east-1"

# ─── VPC wählen ───────────────────────────────────────────────────────────────
select_vpc() {
    if [ -f "$SCRIPT_DIR/01_output.env" ] && grep -q "VPC_ID=vpc-" "$SCRIPT_DIR/01_output.env"; then
        source "$SCRIPT_DIR/01_output.env"
        echo -e "  Aktives VPC: ${CYAN}$VPC_ID${NC}  ($VPC_CIDR)"
        read -rp "  Dieses VPC verwenden? [J/n]: " USE_CURRENT
        [[ ! "$USE_CURRENT" =~ ^[Nn]$ ]] && return 0
    fi

    echo -e "${YELLOW}VPCs in $REGION abfragen...${NC}"
    VPC_RAW=$(aws ec2 describe-vpcs \
        --query "Vpcs[].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
        --output text --region "$REGION" 2>/dev/null)

    [ -z "$VPC_RAW" ] && echo -e "${RED}Keine VPCs gefunden.${NC}" && return 1

    VPC_IDS_SEL=()
    local IDX=0
    while IFS=$'\t' read -r VID VCIDR VNAME; do
        [ "$VNAME" == "None" ] && VNAME="-"
        VPC_IDS_SEL[$IDX]="$VID"
        echo -e "  ${CYAN}[$((IDX+1))]${NC}  $VID  $VCIDR  ${DIM}$VNAME${NC}"
        (( IDX++ ))
    done <<< "$VPC_RAW"

    echo ""
    read -rp "VPC auswaehlen [1-$IDX]: " SEL
    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$IDX" ]; then
        echo -e "${RED}Ungueltige Auswahl.${NC}"; return 1
    fi
    VPC_ID="${VPC_IDS_SEL[$((SEL-1))]}"
    VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
        --query "Vpcs[0].CidrBlock" --output text --region "$REGION" 2>/dev/null)
}

# ─── Subnetze für LB auswählen ────────────────────────────────────────────────
select_lb_subnets() {
    echo ""
    echo -e "${YELLOW}Subnetze in VPC $VPC_ID:${NC}"

    SN_RAW=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "Subnets[].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key=='Name']|[0].Value,MapPublicIpOnLaunch]" \
        --output text --region "$REGION" 2>/dev/null)

    [ -z "$SN_RAW" ] && echo -e "${RED}Keine Subnetze gefunden.${NC}" && return 1

    SN_IDS_SEL=(); SN_AZS_SEL=()
    local IDX=0
    while IFS=$'\t' read -r SID SAZ SCIDR SNAME SPUB; do
        [ "$SNAME" == "None" ] && SNAME="$SID"
        SN_IDS_SEL[$IDX]="$SID"
        SN_AZS_SEL[$IDX]="$SAZ"
        [ "$SPUB" == "True" ] && PUB_LABEL="${GREEN}[Public]${NC}" || PUB_LABEL="${RED}[Private]${NC}"
        echo -e "  ${CYAN}[$((IDX+1))]${NC}  $SNAME  $SCIDR  $SAZ  $PUB_LABEL"
        (( IDX++ ))
    done <<< "$SN_RAW"

    echo ""
    echo -e "  ${DIM}Waehlen Sie die Subnetze, die der Load Balancer verwenden soll.${NC}"
    echo -e "  ${DIM}Mindestens 2 Subnetze in verschiedenen AZs erforderlich. Fuer internet-facing ALB: Public Subnetze waehlen.${NC}"
    echo ""
    read -rp "  Subnetz-Auswahl (kommagetrennt, z.B. 1,2): " SN_SEL_INPUT

    LB_SUBNET_IDS=()
    local AZ_CHECK=()
    IFS=',' read -ra SN_PARTS <<< "$SN_SEL_INPUT"
    for P in "${SN_PARTS[@]}"; do
        P=$(echo "$P" | tr -d ' \r')
        if [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le "$IDX" ]; then
            local I=$((P-1))
            LB_SUBNET_IDS[${#LB_SUBNET_IDS[@]}]="${SN_IDS_SEL[$I]}"
            AZ_CHECK[${#AZ_CHECK[@]}]="${SN_AZS_SEL[$I]}"
        fi
    done

    if [ ${#LB_SUBNET_IDS[@]} -lt 2 ]; then
        echo -e "${RED}Mindestens 2 Subnetze erforderlich.${NC}"; return 1
    fi

    # AZ-Diversitaet pruefen
    local AZ1="${AZ_CHECK[0]}"
    local ALL_SAME=true
    for AZ in "${AZ_CHECK[@]}"; do
        [ "$AZ" != "$AZ1" ] && ALL_SAME=false && break
    done
    if $ALL_SAME; then
        echo -e "${RED}Alle gewahlten Subnetze sind in derselben AZ ($AZ1).${NC}"
        echo -e "${RED}ALB benoetigt Subnetze in verschiedenen AZs.${NC}"
        return 1
    fi
    echo -e "  ${GREEN}✓ AZ-Pruefung bestanden${NC}"
}

# ─── Security Group für LB wählen ─────────────────────────────────────────────
select_lb_sg() {
    echo ""
    echo -e "${YELLOW}Security Groups in VPC $VPC_ID:${NC}"

    SG_RAW=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[].[GroupId,GroupName]" \
        --output text --region "$REGION" 2>/dev/null)

    SG_IDS_SEL=()
    local IDX=0
    while IFS=$'\t' read -r SGID SGNAME; do
        SG_IDS_SEL[$IDX]="$SGID"
        # Prüfen welche Listener-Ports bereits in dieser SG offen sind
        local _PORT_HINTS=""
        local _CHECK_PORTS=()
        if [ ${#LISTENER_PORTS[@]} -gt 0 ]; then
            _CHECK_PORTS=("${LISTENER_PORTS[@]}")
        else
            _CHECK_PORTS=("${LISTENER_PORT:-80}")
        fi
        for _CP in "${_CHECK_PORTS[@]}"; do
            local _OPEN
            _OPEN=$(aws ec2 describe-security-groups --group-ids "$SGID" --region "$REGION" \
                --query "SecurityGroups[0].IpPermissions[?FromPort==\`$_CP\` && ToPort==\`$_CP\` && contains(IpRanges[].CidrIp, '0.0.0.0/0')]" \
                --output text 2>/dev/null)
            if [ -n "$_OPEN" ]; then
                _PORT_HINTS+=" ${GREEN}✓ Port $_CP${NC}"
            else
                _PORT_HINTS+=" ${RED}✗ Port $_CP${NC}"
            fi
        done
        echo -e "  ${CYAN}[$((IDX+1))]${NC}  $SGNAME  ${DIM}$SGID${NC} —$_PORT_HINTS"
        (( IDX++ ))
    done <<< "$SG_RAW"
    # LISTENER_PORTS gesetzt wenn aus create_lb aufgerufen, sonst Fallback auf LISTENER_PORT
    local _SG_PORTS_LABEL
    if [ ${#LISTENER_PORTS[@]} -gt 0 ]; then
        _SG_PORTS_LABEL="${LISTENER_PORTS[*]}"
    else
        _SG_PORTS_LABEL="${LISTENER_PORT:-80}"
    fi
    echo -e "  ${CYAN}[$((IDX+1))]${NC}  Neue SG fuer LB erstellen  ${DIM}(Port(s) $_SG_PORTS_LABEL von ueberall)${NC}"

    echo ""
    read -rp "  Auswahl: " SG_SEL

    if [ "$SG_SEL" == "$((IDX+1))" ]; then
        LB_SG_ID=$(aws ec2 create-security-group \
            --group-name "sg-lb-$(date +%s)" \
            --description "Load Balancer SG ports $_SG_PORTS_LABEL" \
            --vpc-id "$VPC_ID" --region "$REGION" \
            --query "GroupId" --output text)
        if [ -z "$LB_SG_ID" ] || [ "$LB_SG_ID" == "None" ]; then
            echo -e "${RED}Fehler: Security Group konnte nicht erstellt werden.${NC}"; return 1
        fi
        if [ ${#LISTENER_PORTS[@]} -gt 0 ]; then
            for _SP in "${LISTENER_PORTS[@]}"; do
                aws ec2 authorize-security-group-ingress \
                    --group-id "$LB_SG_ID" --protocol tcp --port "$_SP" --cidr 0.0.0.0/0 \
                    --region "$REGION" > /dev/null
            done
        else
            aws ec2 authorize-security-group-ingress \
                --group-id "$LB_SG_ID" --protocol tcp --port "${LISTENER_PORT:-80}" --cidr 0.0.0.0/0 \
                --region "$REGION" > /dev/null
        fi
        echo -e "  ${GREEN}✓ Neue SG erstellt:${NC} $LB_SG_ID  ${DIM}(Port(s) $_SG_PORTS_LABEL offen)${NC}"
    elif [[ "$SG_SEL" =~ ^[0-9]+$ ]] && [ "$SG_SEL" -ge 1 ] && [ "$SG_SEL" -le "$IDX" ]; then
        LB_SG_ID="${SG_IDS_SEL[$((SG_SEL-1))]}"
        echo -e "  ${GREEN}✓ Gewaehlt:${NC} $LB_SG_ID"
    else
        echo -e "${RED}Ungueltige Auswahl.${NC}"; return 1
    fi
}

# ─── Load Balancer erstellen ───────────────────────────────────────────────────
create_lb() {
    echo -e "${BOLD}=== Load Balancer erstellen ===${NC}"
    echo ""
    select_vpc || return
    select_lb_subnets || return

    echo ""
    read -rp "  Load Balancer Name [alb-lab]: " LB_NAME
    LB_NAME="${LB_NAME:-alb-lab}"

    echo ""
    echo -e "  Schema:"
    echo -e "    [1] internet-facing  ${DIM}(oeffentlich erreichbar)${NC}"
    echo -e "    [2] internal         ${DIM}(nur intern im VPC)${NC}"
    read -rp "  Auswahl [1]: " SCHEME_SEL
    [ "${SCHEME_SEL:-1}" == "2" ] && LB_SCHEME="internal" || LB_SCHEME="internet-facing"

    echo ""
    read -rp "  Target Group Name [tg-lab]: " TG_NAME
    TG_NAME="${TG_NAME:-tg-lab}"
    echo ""
    echo -e "  ${BOLD}Port-Konfiguration:${NC}"
    echo -e "  ${DIM}Eingehende Ports = was der LB von aussen empfaengt (je ein Listener pro Port)${NC}"
    echo -e "  ${DIM}Ziel-Port        = Port auf der EC2-Instanz (Target Group)${NC}"
    echo ""
    read -rp "  Eingehende Ports (kommagetrennt) [80]: " LISTENER_PORTS_INPUT
    LISTENER_PORTS_INPUT="${LISTENER_PORTS_INPUT:-80}"
    read -rp "  Ziel-Port auf der Instanz        [80]: " TG_PORT
    TG_PORT="${TG_PORT:-80}"

    # Ports parsen und validieren
    declare -a LISTENER_PORTS
    IFS=',' read -ra _LP_PARTS <<< "$LISTENER_PORTS_INPUT"
    for _P in "${_LP_PARTS[@]}"; do
        _P=$(echo "$_P" | tr -d ' \r')
        if [[ "$_P" =~ ^[0-9]+$ ]] && [ "$_P" -ge 1 ] && [ "$_P" -le 65535 ]; then
            LISTENER_PORTS[${#LISTENER_PORTS[@]}]="$_P"
        else
            echo -e "  ${YELLOW}Port '$_P' uebersprungen (ungueltig)${NC}"
        fi
    done
    [ ${#LISTENER_PORTS[@]} -eq 0 ] && LISTENER_PORTS=(80)
    LISTENER_PORT="${LISTENER_PORTS[0]}"   # fuer SG-Erstellung (erster Port)

    echo -e "  ${GREEN}✓ Listener-Ports:${NC} ${LISTENER_PORTS[*]}"

    select_lb_sg || return

    # Target Group erstellen
    echo ""
    echo -e "${YELLOW}[1/3] Target Group erstellen...${NC}"
    TG_ARN=$(aws elbv2 create-target-group \
        --name "$TG_NAME" \
        --protocol HTTP \
        --port "$TG_PORT" \
        --vpc-id "$VPC_ID" \
        --target-type instance \
        --region "$REGION" \
        --query "TargetGroups[0].TargetGroupArn" --output text 2>&1)

    if [[ "$TG_ARN" != arn:* ]]; then
        echo -e "${RED}Fehler TG: $TG_ARN${NC}"; return 1
    fi
    echo -e "  ${GREEN}✓ $TG_NAME${NC}"

    # EC2 Instanzen als Targets registrieren
    echo ""
    echo -e "${YELLOW}Laufende Instanzen im VPC:${NC}"
    INST_RAW=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value,PrivateIpAddress]" \
        --output text --region "$REGION" 2>/dev/null)

    INST_IDS_SEL=()
    local IDX=0
    if [ -n "$INST_RAW" ]; then
        while IFS=$'\t' read -r IID INAME IIP; do
            [ "$INAME" == "None" ] && INAME="$IID"
            INST_IDS_SEL[$IDX]="$IID"
            echo -e "  ${CYAN}[$((IDX+1))]${NC}  $INAME  ${DIM}$IIP  $IID${NC}"
            (( IDX++ ))
        done <<< "$INST_RAW"
        echo ""
        echo -e "  ${DIM}Nummern kommagetrennt, oder Enter fuer keine:${NC}"
        read -rp "  Instanzen registrieren: " INST_SEL_INPUT

        if [ -n "$INST_SEL_INPUT" ]; then
            TARGETS=""
            IFS=',' read -ra INST_PARTS <<< "$INST_SEL_INPUT"
            for P in "${INST_PARTS[@]}"; do
                P=$(echo "$P" | tr -d ' \r')
                [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le "$IDX" ] \
                    && TARGETS="$TARGETS Id=${INST_IDS_SEL[$((P-1))]}"
            done
            if [ -n "$TARGETS" ]; then
                aws elbv2 register-targets \
                    --target-group-arn "$TG_ARN" \
                    --targets $TARGETS \
                    --region "$REGION" > /dev/null
                echo -e "  ${GREEN}✓ Targets registriert${NC}"
            fi
        fi
    else
        echo -e "  ${DIM}Keine laufenden Instanzen.${NC}"
    fi

    # Load Balancer erstellen
    echo ""
    echo -e "${YELLOW}[2/3] Load Balancer erstellen...${NC}"
    SUBNET_ARGS=""
    for SID in "${LB_SUBNET_IDS[@]}"; do SUBNET_ARGS="$SUBNET_ARGS $SID"; done

    LB_ARN=$(aws elbv2 create-load-balancer \
        --name "$LB_NAME" \
        --subnets $SUBNET_ARGS \
        --security-groups "$LB_SG_ID" \
        --scheme "$LB_SCHEME" \
        --type application \
        --ip-address-type ipv4 \
        --region "$REGION" \
        --query "LoadBalancers[0].LoadBalancerArn" --output text 2>&1)

    if [[ "$LB_ARN" != arn:* ]]; then
        echo -e "${RED}Fehler LB: $LB_ARN${NC}"; return 1
    fi

    LB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$LB_ARN" \
        --query "LoadBalancers[0].DNSName" --output text --region "$REGION" 2>/dev/null)
    echo -e "  ${GREEN}✓ $LB_NAME${NC}: $LB_DNS"

    # Listener erstellen (je einen pro Port)
    echo ""
    echo -e "${YELLOW}[3/3] Listener erstellen (${#LISTENER_PORTS[@]} Port(s))...${NC}"
    for LP in "${LISTENER_PORTS[@]}"; do
        L_ARN=$(aws elbv2 create-listener \
            --load-balancer-arn "$LB_ARN" \
            --protocol HTTP --port "$LP" \
            --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
            --region "$REGION" \
            --query "Listeners[0].ListenerArn" --output text 2>&1)
        if [[ "$L_ARN" == arn:* ]]; then
            echo -e "  ${GREEN}✓ Listener HTTP:${LP} → $TG_NAME (Port $TG_PORT)${NC}"
        else
            echo -e "  ${RED}Fehler Port $LP: $L_ARN${NC}"
        fi
    done

    echo ""
    echo -e "${BOLD}=== Load Balancer erstellt ===${NC}"
    echo ""
    echo -e "  Name:        ${CYAN}$LB_NAME${NC}"
    echo -e "  DNS:         ${CYAN}$LB_DNS${NC}"
    echo -e "  Schema:      ${CYAN}$LB_SCHEME${NC}"
    echo -e "  Eingehend:   ${CYAN}Port(s): ${LISTENER_PORTS[*]}${NC}  ${DIM}(Listener)${NC}"
    echo -e "  Ziel:        ${CYAN}$TG_NAME  Port $TG_PORT${NC}  ${DIM}(Target Group)${NC}"
    echo ""
    for LP in "${LISTENER_PORTS[@]}"; do
        echo -e "  Testen: ${CYAN}curl http://$LB_DNS:${LP}${NC}"
    done
    echo -e "  ${DIM}(kann 1-2 Minuten dauern bis der LB aktiv ist)${NC}"
}

# ─── Load Balancer anzeigen ───────────────────────────────────────────────────
show_lbs() {
    echo -e "${BOLD}─── Load Balancer in $REGION ─────────────────────────${NC}"
    echo ""

    LB_RAW=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[].[LoadBalancerName,DNSName,State.Code,Scheme,Type,VpcId]" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$LB_RAW" ]; then
        echo -e "  ${DIM}Keine Load Balancer vorhanden.${NC}"; return
    fi

    while IFS=$'\t' read -r LBNAME LBDNS LBSTATE LBSCHEME LBTYPE LBVPC; do
        [ "$LBSTATE" == "active" ] && S="${GREEN}●${NC}" || S="${YELLOW}●${NC}"
        echo -e "  $S ${BOLD}$LBNAME${NC}  ${DIM}[$LBTYPE / $LBSCHEME]${NC}"
        echo -e "     DNS:   ${CYAN}$LBDNS${NC}"
        echo -e "     State: $LBSTATE   VPC: $LBVPC"
        echo ""
    done <<< "$LB_RAW"
}

# ─── Load Balancer löschen ────────────────────────────────────────────────────
delete_lb() {
    echo -e "${BOLD}─── Load Balancer loeschen ──────────────────────────${NC}"
    echo ""

    LB_RAW=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[].[LoadBalancerArn,LoadBalancerName]" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$LB_RAW" ]; then
        echo -e "  ${DIM}Keine Load Balancer vorhanden.${NC}"; return
    fi

    LB_ARNS_SEL=()
    local IDX=0
    while IFS=$'\t' read -r LBARN LBNAME; do
        LB_ARNS_SEL[$IDX]="$LBARN"
        echo -e "  ${CYAN}[$((IDX+1))]${NC}  $LBNAME"
        (( IDX++ ))
    done <<< "$LB_RAW"

    echo ""
    read -rp "LB zum Loeschen [1-$IDX]: " SEL
    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$IDX" ]; then
        echo -e "${RED}Ungueltige Auswahl.${NC}"; return
    fi
    SEL_ARN="${LB_ARNS_SEL[$((SEL-1))]}"

    # Target Groups vor dem Loeschen merken
    TG_ARNS=$(aws elbv2 describe-target-groups \
        --load-balancer-arn "$SEL_ARN" \
        --query "TargetGroups[].TargetGroupArn" \
        --output text --region "$REGION" 2>/dev/null)

    # Listeners loeschen
    LISTENER_ARNS=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$SEL_ARN" \
        --query "Listeners[].ListenerArn" \
        --output text --region "$REGION" 2>/dev/null)
    for LARN in $LISTENER_ARNS; do
        aws elbv2 delete-listener --listener-arn "$LARN" --region "$REGION" 2>/dev/null
    done

    read -rp "  Wirklich loeschen? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return

    RESULT=$(aws elbv2 delete-load-balancer \
        --load-balancer-arn "$SEL_ARN" --region "$REGION" 2>&1)

    if echo "$RESULT" | grep -qi "error"; then
        echo -e "  ${RED}Fehler: $RESULT${NC}"
    else
        echo -e "  ${GREEN}✓ Load Balancer geloescht${NC}"
    fi

    if [ -n "$TG_ARNS" ]; then
        echo ""
        read -rp "  Target Groups ebenfalls loeschen? [j/N]: " TG_CONFIRM
        if [[ "$TG_CONFIRM" =~ ^[JjYy]$ ]]; then
            for TGARN in $TG_ARNS; do
                aws elbv2 delete-target-group \
                    --target-group-arn "$TGARN" --region "$REGION" > /dev/null 2>&1
                echo -e "  ${GREEN}✓ Target Group geloescht${NC}"
            done
        fi
    fi
}

# ─── Zielgruppen anzeigen ─────────────────────────────────────────────────────
show_target_groups() {
    echo -e "${BOLD}─── Zielgruppen (Target Groups) in $REGION ──────────${NC}"
    echo ""

    TG_LIST=$(aws elbv2 describe-target-groups \
        --query "TargetGroups[].[TargetGroupName,TargetGroupArn,Protocol,Port,VpcId,HealthCheckPath]" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$TG_LIST" ]; then
        echo -e "  ${DIM}Keine Zielgruppen vorhanden.${NC}"; return
    fi

    while IFS=$'\t' read -r TGNAME TGARN TGPROTO TGPORT TGVPC TGHC; do
        echo -e "  ${BOLD}$TGNAME${NC}  ${DIM}[$TGPROTO:$TGPORT  VPC: $TGVPC]${NC}"
        echo -e "     Health-Check-Pfad: ${CYAN}$TGHC${NC}"

        # Targets + Health-Status abfragen
        HEALTH_RAW=$(aws elbv2 describe-target-health \
            --target-group-arn "$TGARN" \
            --query "TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Description]" \
            --output text --region "$REGION" 2>/dev/null)

        if [ -z "$HEALTH_RAW" ]; then
            echo -e "     ${DIM}Keine Targets registriert.${NC}"
        else
            while IFS=$'\t' read -r TID TSTATE TDESC; do
                case "$TSTATE" in
                    healthy)   S="${GREEN}●${NC}" ;;
                    unhealthy) S="${RED}●${NC}" ;;
                    *)         S="${YELLOW}●${NC}" ;;
                esac
                TDESC_OUT="${TDESC:+  → $TDESC}"
                echo -e "     $S $TID  ${DIM}$TSTATE$TDESC_OUT${NC}"
            done <<< "$HEALTH_RAW"
        fi
        echo ""
    done <<< "$TG_LIST"
}

# ─── Zielgruppe erstellen ─────────────────────────────────────────────────────
create_target_group() {
    echo -e "${BOLD}─── Zielgruppe erstellen ────────────────────────────${NC}"
    echo ""
    select_vpc || return

    echo ""
    read -rp "  Name [tg-lab]: " TG_NAME
    TG_NAME="${TG_NAME:-tg-lab}"

    echo ""
    echo -e "  ${BOLD}Port-Konfiguration:${NC}"
    echo -e "  ${DIM}Ziel-Port = Port auf der EC2-Instanz (z.B. 80 fuer httpd)${NC}"
    read -rp "  Ziel-Port [80]: " TG_PORT
    TG_PORT="${TG_PORT:-80}"

    echo ""
    echo -e "  ${DIM}Health-Check-Pfad: URL-Pfad den der LB zur Zustandspruefung aufruft${NC}"
    read -rp "  Health-Check-Pfad [/]: " HC_PATH
    HC_PATH="${HC_PATH:-/}"

    echo ""
    echo -e "${YELLOW}Zielgruppe erstellen...${NC}"
    NEW_TG_ARN=$(aws elbv2 create-target-group \
        --name "$TG_NAME" \
        --protocol HTTP \
        --port "$TG_PORT" \
        --vpc-id "$VPC_ID" \
        --target-type instance \
        --health-check-path "$HC_PATH" \
        --region "$REGION" \
        --query "TargetGroups[0].TargetGroupArn" --output text 2>&1)

    if [[ "$NEW_TG_ARN" != arn:* ]]; then
        echo -e "${RED}Fehler: $NEW_TG_ARN${NC}"; return 1
    fi
    echo -e "  ${GREEN}✓ $TG_NAME${NC}  Port $TG_PORT  HC: $HC_PATH"
    echo -e "  ARN: ${DIM}$NEW_TG_ARN${NC}"

    # Instanzen registrieren
    echo ""
    echo -e "${YELLOW}Laufende Instanzen im VPC:${NC}"
    INST_RAW=$(aws ec2 describe-instances \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value,PrivateIpAddress]" \
        --output text --region "$REGION" 2>/dev/null)

    INST_IDS_SEL=()
    local IDX=0
    if [ -n "$INST_RAW" ]; then
        while IFS=$'\t' read -r IID INAME IIP; do
            [ "$INAME" == "None" ] && INAME="$IID"
            INST_IDS_SEL[$IDX]="$IID"
            echo -e "  ${CYAN}[$((IDX+1))]${NC}  $INAME  ${DIM}$IIP  $IID${NC}"
            (( IDX++ ))
        done <<< "$INST_RAW"
        echo ""
        echo -e "  ${DIM}Nummern kommagetrennt, oder Enter fuer keine:${NC}"
        read -rp "  Instanzen registrieren: " INST_SEL_INPUT

        if [ -n "$INST_SEL_INPUT" ]; then
            TARGETS=""
            IFS=',' read -ra INST_PARTS <<< "$INST_SEL_INPUT"
            for P in "${INST_PARTS[@]}"; do
                P=$(echo "$P" | tr -d ' \r')
                [[ "$P" =~ ^[0-9]+$ ]] && [ "$P" -ge 1 ] && [ "$P" -le "$IDX" ] \
                    && TARGETS="$TARGETS Id=${INST_IDS_SEL[$((P-1))]}"
            done
            if [ -n "$TARGETS" ]; then
                aws elbv2 register-targets \
                    --target-group-arn "$NEW_TG_ARN" \
                    --targets $TARGETS \
                    --region "$REGION" > /dev/null
                echo -e "  ${GREEN}✓ Targets registriert${NC}"
            fi
        fi
    else
        echo -e "  ${DIM}Keine laufenden Instanzen.${NC}"
    fi
}

# ─── Hauptmenü ────────────────────────────────────────────────────────────────
while true; do
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           Load Balancer verwalten               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Region: ${CYAN}$REGION${NC}"
    echo ""
    echo -e "${BOLD}─── Load Balancer ───────────────────────────────────${NC}"
    echo -e "  ${CYAN}[1]${NC}  Load Balancer erstellen"
    echo -e "       ${DIM}→ VPC + Subnetze (mind. 2 AZs) + ALB + Target Group + Listener${NC}"
    echo -e "  ${CYAN}[2]${NC}  Load Balancer anzeigen"
    echo -e "  ${CYAN}[3]${NC}  Load Balancer loeschen"
    echo ""
    echo -e "${BOLD}─── Zielgruppen ─────────────────────────────────────${NC}"
    echo -e "  ${CYAN}[4]${NC}  Zielgruppen anzeigen  ${DIM}(inkl. Health-Status der Targets)${NC}"
    echo -e "  ${CYAN}[5]${NC}  Zielgruppe erstellen  ${DIM}(standalone, ohne LB)${NC}"
    echo ""
    echo -e "  ${CYAN}[0]${NC}  Zurueck"
    echo ""
    read -rp "Auswahl: " CHOICE

    case "$CHOICE" in
        1) clear; create_lb; read -rp "Enter zum Fortfahren..." ;;
        2) clear; show_lbs; read -rp "Enter zum Fortfahren..." ;;
        3) clear; delete_lb; read -rp "Enter zum Fortfahren..." ;;
        4) clear; show_target_groups; read -rp "Enter zum Fortfahren..." ;;
        5) clear; create_target_group; read -rp "Enter zum Fortfahren..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ungueltige Auswahl.${NC}"; sleep 1 ;;
    esac
done
