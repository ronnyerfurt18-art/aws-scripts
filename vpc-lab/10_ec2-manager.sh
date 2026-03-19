#!/bin/bash

# EC2 Manager – Instanzen anlegen, starten, stoppen, verbinden
# Linux (Amazon Linux 2023) und Windows (Server 2022)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.env"

[ -f "$CONFIG" ] && source "$CONFIG"
[ -z "$REGION" ] && REGION="us-east-1"

# ─── Hilfsfunktion: alle Instanzen auflisten ──────────────────────────────────
list_instances() {
    echo -e "${BOLD}─── EC2 Instanzen in $REGION ────────────────────────${NC}"
    echo ""

    RAW=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PublicIpAddress,PrivateIpAddress,Platform,Tags[?Key=='Name'].Value|[0]]" \
        --output text --region "$REGION" 2>/dev/null)

    if [ -z "$RAW" ]; then
        echo -e "  ${DIM}Keine Instanzen gefunden.${NC}"
        return
    fi

    declare -ga INST_IDS INST_NAMES INST_STATES INST_TYPES INST_PLATFORMS
    INST_IDS=(); INST_NAMES=(); INST_STATES=(); INST_TYPES=(); INST_PLATFORMS=()
    local i=1

    while IFS=$'\t' read -r IID ITYPE STATE PUB PRIV PLATFORM NAME; do
        [ -z "$IID" ] && continue
        [ "$PLATFORM" == "None" ] || [ -z "$PLATFORM" ] && PLATFORM="Linux"
        [ "$NAME"  == "None" ] || [ -z "$NAME"  ] && NAME="(kein Name)"
        [ "$PUB"   == "None" ] || [ -z "$PUB"   ] && PUB="-"
        [ "$PRIV"  == "None" ] || [ -z "$PRIV"  ] && PRIV="-"

        case "$STATE" in
            running)  S="${GREEN}● running${NC}" ;;
            stopped)  S="${RED}● stopped${NC}" ;;
            stopping) S="${YELLOW}● stopping${NC}" ;;
            pending)  S="${YELLOW}● pending${NC}" ;;
            *)        S="${DIM}● $STATE${NC}" ;;
        esac

        [ "$PLATFORM" == "Linux" ] && OS="${GREEN}Linux${NC}" || OS="${CYAN}Windows${NC}"

        echo -e "  [${CYAN}$i${NC}] ${BOLD}$NAME${NC}  ($IID)"
        echo -e "       $S  |  $OS  |  $ITYPE"
        echo -e "       ${DIM}pub: $PUB   priv: $PRIV${NC}"
        echo ""

        INST_IDS[$i]="$IID"
        INST_NAMES[$i]="$NAME"
        INST_STATES[$i]="$STATE"
        INST_TYPES[$i]="$ITYPE"
        INST_PLATFORMS[$i]="$PLATFORM"
        ((i++))
    done <<< "$RAW"

    INST_COUNT=$((i - 1))
}

# ─── Instanz auswaehlen ───────────────────────────────────────────────────────
select_instance() {
    local PROMPT="${1:-Instanz auswaehlen}"
    list_instances
    [ "$INST_COUNT" -eq 0 ] && return 1
    read -rp "  $PROMPT [Nummer]: " SEL
    [ "$SEL" == "0" ] && return 1
    if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "$INST_COUNT" ]; then
        SELECTED_IID="${INST_IDS[$SEL]}"
        SELECTED_NAME="${INST_NAMES[$SEL]}"
        SELECTED_STATE="${INST_STATES[$SEL]}"
        SELECTED_TYPE="${INST_TYPES[$SEL]}"
        SELECTED_PLATFORM="${INST_PLATFORMS[$SEL]}"
        return 0
    fi
    echo -e "${RED}Ungueltige Auswahl.${NC}"; return 1
}

# ─── Neue Instanz erstellen ───────────────────────────────────────────────────
create_instance() {
    clear
    echo -e "${BOLD}─── Neue EC2 Instanz erstellen ──────────────────────${NC}"
    echo ""

    # Name
    read -rp "  Name der Instanz: " INST_NAME
    [ -z "$INST_NAME" ] && echo -e "${RED}Kein Name angegeben.${NC}" && return

    # Betriebssystem
    echo ""
    echo -e "  Betriebssystem:"
    echo -e "    [1] Amazon Linux 2023  ${DIM}(SSH, kostenguenstig)${NC}"
    echo -e "    [2] Windows Server 2022  ${DIM}(RDP, teuerer)${NC}"
    read -rp "  Auswahl [1]: " OS_SEL

    if [ "${OS_SEL:-1}" == "2" ]; then
        PLATFORM="Windows"
        echo -e "  ${YELLOW}Lade aktuelles Windows AMI...${NC}"
        AMI_ID=$(aws ssm get-parameter \
            --name "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base" \
            --query "Parameter.Value" --output text --region "$REGION" 2>/dev/null)
        AMI_LABEL="Windows Server 2022"
        DEFAULT_USER="Administrator"
    else
        PLATFORM="Linux"
        echo -e "  ${YELLOW}Lade aktuelles Amazon Linux 2023 AMI...${NC}"
        AMI_ID=$(aws ssm get-parameter \
            --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
            --query "Parameter.Value" --output text --region "$REGION" 2>/dev/null)
        AMI_LABEL="Amazon Linux 2023"
        DEFAULT_USER="ec2-user"
    fi

    if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
        echo -e "${RED}AMI nicht gefunden. Region pruefen: $REGION${NC}"; return
    fi
    echo -e "  ${GREEN}✓ AMI: $AMI_ID${NC}  ($AMI_LABEL)"

    # Instance Type
    echo ""
    echo -e "  Instance Type:"
    echo -e "    [1] t2.micro   1 vCPU  1 GB   ${DIM}(Free Tier)${NC}"
    echo -e "    [2] t3.micro   2 vCPU  1 GB"
    echo -e "    [3] t3.small   2 vCPU  2 GB"
    echo -e "    [4] t3.medium  2 vCPU  4 GB"
    echo -e "    [5] t3.large   2 vCPU  8 GB   ${DIM}(Windows empfohlen)${NC}"
    read -rp "  Auswahl [1]: " IT_SEL
    case "${IT_SEL:-1}" in
        2) INSTANCE_TYPE="t3.micro" ;;
        3) INSTANCE_TYPE="t3.small" ;;
        4) INSTANCE_TYPE="t3.medium" ;;
        5) INSTANCE_TYPE="t3.large" ;;
        *) INSTANCE_TYPE="t2.micro" ;;
    esac

    # Key Pair – vorhandene anzeigen und auswaehlen
    echo ""
    echo -e "  ${BOLD}Key Pair:${NC}"
    KP_RAW=$(aws ec2 describe-key-pairs \
        --query "KeyPairs[].KeyName" \
        --output text --region "$REGION" 2>/dev/null | tr '\t' '\n' | grep -v '^$')

    if [ -z "$KP_RAW" ]; then
        echo -e "  ${YELLOW}Keine Key Pairs in Region $REGION gefunden.${NC}"
        echo -e "  ${DIM}Bitte zuerst unter Menue-Punkt [3] ein Key Pair erstellen.${NC}"
        echo ""
        read -rp "  Zum Menue zurueck? [j] oder Key-Name manuell eingeben: " KP_INPUT
        if [[ "$KP_INPUT" =~ ^[JjYy]$ ]] || [ -z "$KP_INPUT" ]; then
            return
        fi
        KP_NAME="$KP_INPUT"
    else
        declare -a KP_ARR
        local i=1
        while IFS= read -r kp; do
            [ -z "$kp" ] && continue
            PEM_LABEL=""
            [ -f "$SCRIPT_DIR/${kp}.pem" ] && PEM_LABEL="${GREEN} ✓ .pem vorhanden${NC}"
            ACTIVE_LABEL=""
            [ "$kp" == "$KEY_NAME" ] && ACTIVE_LABEL="${CYAN} [aktiv]${NC}"
            echo -e "    [${CYAN}$i${NC}] $kp$PEM_LABEL$ACTIVE_LABEL"
            KP_ARR[$i]="$kp"
            ((i++))
        done <<< "$KP_RAW"

        # Vorauswahl: aktiver Key aus config.env
        DEFAULT_IDX=""
        for j in "${!KP_ARR[@]}"; do
            [ "${KP_ARR[$j]}" == "$KEY_NAME" ] && DEFAULT_IDX=$j && break
        done

        echo ""
        read -rp "  Auswahl [${DEFAULT_IDX:-1}]: " KP_SEL
        KP_SEL="${KP_SEL:-${DEFAULT_IDX:-1}}"

        if [[ "$KP_SEL" =~ ^[0-9]+$ ]] && [ -n "${KP_ARR[$KP_SEL]}" ]; then
            KP_NAME="${KP_ARR[$KP_SEL]}"
        else
            echo -e "  ${RED}Ungueltige Auswahl.${NC}"; return
        fi

        # Warnung wenn .pem fehlt
        if [ ! -f "$SCRIPT_DIR/${KP_NAME}.pem" ]; then
            echo -e "  ${YELLOW}⚠  .pem fuer '$KP_NAME' nicht lokal gefunden – SSH spaeter nicht moeglich.${NC}"
            read -rp "  Trotzdem fortfahren? [j/N]: " CONT
            [[ ! "$CONT" =~ ^[JjYy]$ ]] && return
        fi
    fi

    # VPC / Subnetz
    echo ""
    echo -e "  Netzwerk:"
    echo -e "    [1] Default VPC  ${DIM}(Standard, kein Setup noetig)${NC}"

    # Lab-Subnetze anzeigen falls vorhanden
    LAB_SUBNETS=()
    if [ -f "$SCRIPT_DIR/01_output.env" ] && grep -q "VPC_ID=vpc-" "$SCRIPT_DIR/01_output.env" 2>/dev/null; then
        source "$SCRIPT_DIR/01_output.env"
        for ((n=1; n<=SUBNET_COUNT; n++)); do
            SN_NAME_VAR="SN_NAME_$n"; SID_VAR="SUBNET_ID_$n"; SN_TYPE_VAR="SN_TYPE_$n"
            LAB_SUBNETS+=("${!SID_VAR}|${!SN_NAME_VAR}|${!SN_TYPE_VAR}")
            echo -e "    [$((n+1))] Lab-Subnetz: ${!SN_NAME_VAR} (${!SID_VAR})"
        done
    fi
    read -rp "  Auswahl [1]: " NET_SEL

    SUBNET_ARG=""
    SG_ARG=""
    if [ "${NET_SEL:-1}" != "1" ] && [ -n "${LAB_SUBNETS[$((NET_SEL-2))]}" ]; then
        ENTRY="${LAB_SUBNETS[$((NET_SEL-2))]}"
        SEL_SUBNET=$(echo "$ENTRY" | cut -d'|' -f1)
        SEL_SNAME=$(echo "$ENTRY"  | cut -d'|' -f2)
        SUBNET_ARG="--subnet-id $SEL_SUBNET"
        # passende SG aus 01_output.env nehmen
        IDX=$((NET_SEL - 1))
        SG_VAR="SG_ID_$IDX"
        [ -n "${!SG_VAR}" ] && SG_ARG="--security-group-ids ${!SG_VAR}"
        echo -e "  ${GREEN}Subnetz: $SEL_SNAME ($SEL_SUBNET)${NC}"
    else
        # Default VPC – Default SG ermitteln
        DEFAULT_SG=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=default" \
            --query "SecurityGroups[0].GroupId" \
            --output text --region "$REGION" 2>/dev/null)
        [ -n "$DEFAULT_SG" ] && SG_ARG="--security-group-ids $DEFAULT_SG"
        echo -e "  ${DIM}Default VPC + Default Security Group ($DEFAULT_SG)${NC}"
    fi

    # Public IP
    echo ""
    echo -e "  Oeffentliche IP:"
    echo -e "    [1] Ja  (auto-assign Public IP)"
    echo -e "    [2] Nein"
    read -rp "  Auswahl [1]: " PIP_SEL
    if [ "${PIP_SEL:-1}" == "2" ]; then
        PIP_ARG='--no-associate-public-ip-address'
    else
        PIP_ARG='--associate-public-ip-address'
    fi

    # Zusammenfassung
    echo ""
    echo -e "${BOLD}─── Zusammenfassung ─────────────────────────────────${NC}"
    echo -e "  Name:      ${CYAN}$INST_NAME${NC}"
    echo -e "  OS:        ${CYAN}$AMI_LABEL${NC}  ($AMI_ID)"
    echo -e "  Typ:       ${CYAN}$INSTANCE_TYPE${NC}"
    echo -e "  Key Pair:  ${CYAN}$KP_NAME${NC}"
    echo -e "  Region:    ${CYAN}$REGION${NC}"
    echo ""
    read -rp "  Instanz starten? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && echo -e "${YELLOW}Abgebrochen.${NC}" && return

    echo ""
    echo -e "${YELLOW}Starte Instanz...${NC}"

    IID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KP_NAME" \
        $SUBNET_ARG \
        $SG_ARG \
        $PIP_ARG \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INST_NAME}]" \
        --query "Instances[0].InstanceId" \
        --output text --region "$REGION" 2>&1)

    if echo "$IID" | grep -q "error\|Error\|Invalid"; then
        echo -e "${RED}Fehler: $IID${NC}"; return
    fi

    echo -e "${GREEN}✓ Instanz gestartet: ${CYAN}$IID${NC}"
    echo -e "  ${DIM}Warte auf 'running'...${NC}"
    aws ec2 wait instance-running --instance-ids "$IID" --region "$REGION"

    PUB=$(aws ec2 describe-instances --instance-ids "$IID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text --region "$REGION" 2>/dev/null)
    [ "$PUB" == "None" ] && PUB="-"

    echo ""
    echo -e "${GREEN}✓ Instanz laeuft:${NC}"
    echo -e "  Name:       ${CYAN}$INST_NAME${NC}"
    echo -e "  ID:         ${CYAN}$IID${NC}"
    echo -e "  Public IP:  ${CYAN}$PUB${NC}"
    echo -e "  OS:         ${CYAN}$AMI_LABEL${NC}"
    echo ""

    # ─── Naechster Schritt: Verbindungsinfo direkt anzeigen? ──────────────────
    if [ "$PLATFORM" == "Linux" ]; then
        echo -e "  ${BOLD}Naechster Schritt: Verbindung zur Instanz herstellen.${NC}"
        read -rp "  Verbindungsinfo jetzt anzeigen? [J/n]: " SHOW_CONN
        if [[ ! "$SHOW_CONN" =~ ^[Nn]$ ]]; then
            PEM_FILE="$SCRIPT_DIR/${KP_NAME}.pem"
            [ ! -f "$PEM_FILE" ] && PEM_FILE="~/${KP_NAME}.pem"
            echo ""
            echo -e "${BOLD}─── Verbindungsinfo ─────────────────────────────────${NC}"
            echo -e "  ${BOLD}SSH-Befehl – ausfuehren im Mac-Terminal:${NC}"
            echo -e "  ${CYAN}ssh -i $PEM_FILE $DEFAULT_USER@$PUB${NC}"
            echo ""
            echo -e "  ${BOLD}Erklaerung:${NC}"
            echo -e "  ${DIM}  ssh     → verschluesselte Fernverbindung zum Server${NC}"
            echo -e "  ${DIM}  -i      → gibt den privaten Schluessel an (identity file)${NC}"
            echo -e "  ${DIM}  *.pem   → deine Schluessel-Datei, nur du besitzt sie${NC}"
            echo -e "  ${DIM}  $DEFAULT_USER → Standardbenutzer auf Amazon Linux${NC}"
            echo -e "  ${DIM}  $PUB → oeffentliche IP der Instanz${NC}"
            echo ""
            echo -e "  ${BOLD}Wo ausfuehren:${NC}"
            echo -e "  ${DIM}  Auf deinem Mac, NICHT in AWS.${NC}"
            echo -e "  ${DIM}  Terminal oeffnen: Cmd+Leertaste → 'Terminal' tippen → Enter${NC}"
            echo ""
            echo -e "  ${DIM}  Verbindungsinfo spaeter nochmal abrufbar: Menue [5]${NC}"
        fi
    else
        echo -e "  ${BOLD}Naechster Schritt: RDP-Zugangsdaten abrufen.${NC}"
        read -rp "  Zugangsdaten jetzt anzeigen? [J/n]: " SHOW_CONN
        if [[ ! "$SHOW_CONN" =~ ^[Nn]$ ]]; then
            echo ""
            echo -e "${BOLD}─── RDP-Verbindungsinfo ─────────────────────────────${NC}"
            echo -e "  Host:  ${CYAN}$PUB${NC}"
            echo -e "  Port:  ${CYAN}3389${NC}"
            echo -e "  User:  ${CYAN}Administrator${NC}"
            echo ""
            echo -e "  ${BOLD}Erklaerung:${NC}"
            echo -e "  ${DIM}  RDP  → Remote Desktop Protocol, grafische Fernverbindung${NC}"
            echo -e "  ${DIM}  Mac: Microsoft Remote Desktop aus dem App Store installieren${NC}"
            echo -e "  ${DIM}  Dann: Neue Verbindung → Host: $PUB, Port: 3389${NC}"
            echo ""
            echo -e "  ${YELLOW}Passwort: Windows benoetigt ~10-15 Min nach Start.${NC}"
            echo -e "  ${DIM}  Danach unter Menue [5] abrufbar (wird automatisch entschluesselt).${NC}"
        fi
    fi
}

# ─── Instanz starten / stoppen ────────────────────────────────────────────────
toggle_instance() {
    clear
    select_instance "Instanz auswaehlen" || return

    echo ""
    if [ "$SELECTED_STATE" == "running" ]; then
        echo -e "  Instanz ist ${GREEN}running${NC} – stoppen?"
        read -rp "  Stoppen? [j/N]: " CONFIRM
        [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return
        aws ec2 stop-instances --instance-ids "$SELECTED_IID" --region "$REGION" \
            --query "StoppingInstances[0].CurrentState.Name" --output text 2>/dev/null
        echo -e "  ${YELLOW}✓ $SELECTED_NAME wird gestoppt.${NC}"
    elif [ "$SELECTED_STATE" == "stopped" ]; then
        echo -e "  Instanz ist ${RED}stopped${NC} – starten?"
        read -rp "  Starten? [j/N]: " CONFIRM
        [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return
        aws ec2 start-instances --instance-ids "$SELECTED_IID" --region "$REGION" \
            --query "StartingInstances[0].CurrentState.Name" --output text 2>/dev/null
        echo -e "  ${GREEN}✓ $SELECTED_NAME wird gestartet.${NC}"
    else
        echo -e "  ${YELLOW}Status '$SELECTED_STATE' – kein Start/Stop moeglich.${NC}"
    fi
}

# ─── Instanz terminieren ──────────────────────────────────────────────────────
terminate_instance() {
    clear
    select_instance "Zu terminierende Instanz" || return

    echo ""
    echo -e "  ${RED}WARNUNG: $SELECTED_NAME ($SELECTED_IID) wird unwiderruflich geloescht!${NC}"
    read -rp "  Wirklich terminieren? [j/N]: " CONFIRM
    [[ ! "$CONFIRM" =~ ^[JjYy]$ ]] && return

    aws ec2 terminate-instances --instance-ids "$SELECTED_IID" --region "$REGION" \
        --query "TerminatingInstances[0].CurrentState.Name" --output text 2>/dev/null
    echo -e "  ${GREEN}✓ $SELECTED_NAME wird terminiert.${NC}"
}

# ─── Verbindungsinfo anzeigen ─────────────────────────────────────────────────
connection_info() {
    clear
    select_instance "Verbindungsinfo fuer" || return

    PUB=$(aws ec2 describe-instances --instance-ids "$SELECTED_IID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text --region "$REGION" 2>/dev/null)
    [ "$PUB" == "None" ] || [ -z "$PUB" ] && PUB="(keine Public IP)"

    echo ""
    echo -e "${BOLD}─── Verbindungsinfo: $SELECTED_NAME ─────────────────${NC}"
    echo -e "  Instanz:    ${CYAN}$SELECTED_IID${NC}"
    echo -e "  Public IP:  ${CYAN}$PUB${NC}"
    echo -e "  Typ:        $SELECTED_TYPE"
    echo ""

    if [ "$SELECTED_PLATFORM" == "Linux" ]; then
        PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"
        [ ! -f "$PEM_FILE" ] && PEM_FILE="${KEY_NAME}.pem"
        echo -e "  ${BOLD}SSH-Verbindung (Linux-Terminal auf deinem Mac):${NC}"
        echo -e "  ${CYAN}ssh -i $PEM_FILE ec2-user@$PUB${NC}"
        echo ""
        echo -e "  ${BOLD}Erklaerung:${NC}"
        echo -e "  ${DIM}  ssh          → Programm fuer verschluesselte Fernverbindung${NC}"
        echo -e "  ${DIM}  -i           → 'identity file', gibt den privaten Schluessel an${NC}"
        echo -e "  ${DIM}  $PEM_FILE${NC}"
        echo -e "  ${DIM}               → deine .pem-Datei (privater Schluessel, nur du hast sie)${NC}"
        echo -e "  ${DIM}  ec2-user     → Standard-Benutzername auf Amazon Linux${NC}"
        echo -e "  ${DIM}  $PUB${NC}"
        echo -e "  ${DIM}               → oeffentliche IP-Adresse der Instanz${NC}"
        echo ""
        echo -e "  ${BOLD}Wo ausfuehren:${NC}"
        echo -e "  ${DIM}  Terminal auf deinem Mac (nicht in AWS).${NC}"
        echo -e "  ${DIM}  Terminal oeffnen: Finder → Programme → Dienstprogramme → Terminal${NC}"
        echo -e "  ${DIM}  Oder: Spotlight (Cmd+Leertaste) → 'Terminal' eingeben${NC}"
    else
        echo -e "  ${BOLD}RDP-Verbindung:${NC}"
        echo -e "  Host:  ${CYAN}$PUB${NC}"
        echo -e "  Port:  ${CYAN}3389${NC}"
        echo -e "  User:  ${CYAN}Administrator${NC}"
        echo ""
        echo -e "  ${BOLD}Windows-Passwort abrufen:${NC}"
        PEM_FILE="$SCRIPT_DIR/${KEY_NAME}.pem"
        if [ -f "$PEM_FILE" ]; then
            echo -e "  ${YELLOW}Lade verschluesseltes Passwort...${NC}"
            PW_ENC=$(aws ec2 get-password-data --instance-id "$SELECTED_IID" \
                --query "PasswordData" --output text --region "$REGION" 2>/dev/null)
            if [ -z "$PW_ENC" ] || [ "$PW_ENC" == "None" ]; then
                echo -e "  ${YELLOW}Passwort noch nicht verfuegbar – bitte 10-15 Min nach Start warten.${NC}"
            else
                PW=$(echo "$PW_ENC" | base64 --decode | openssl rsautl -decrypt -inkey "$PEM_FILE" 2>/dev/null)
                if [ -n "$PW" ]; then
                    echo -e "  Passwort: ${CYAN}$PW${NC}"
                else
                    echo -e "  ${DIM}openssl-Entschluesselung fehlgeschlagen. Manuell:${NC}"
                    echo -e "  ${CYAN}aws ec2 get-password-data --instance-id $SELECTED_IID --priv-launch-key $PEM_FILE --region $REGION${NC}"
                fi
            fi
        else
            echo -e "  ${YELLOW}PEM-Datei nicht gefunden: $PEM_FILE${NC}"
            echo -e "  ${DIM}Manuell: aws ec2 get-password-data --instance-id $SELECTED_IID --priv-launch-key <PEM> --region $REGION${NC}"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# HAUPTMENUE
# ══════════════════════════════════════════════════════════════════════════════
while true; do
    [ -f "$CONFIG" ] && source "$CONFIG"
    [ -z "$REGION" ] && REGION="us-east-1"

    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║           EC2 Manager                           ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo -e "  Region: ${CYAN}$REGION${NC}   Key: ${CYAN}${KEY_NAME:-(nicht gesetzt)}${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC} Uebersicht – alle Instanzen anzeigen"
    echo -e "  ${CYAN}[2]${NC} Neue Instanz erstellen  ${DIM}(Linux / Windows)${NC}"
    echo -e "  ${CYAN}[3]${NC} Instanz starten / stoppen"
    echo -e "  ${CYAN}[4]${NC} Instanz terminieren"
    echo -e "  ${CYAN}[5]${NC} Verbindungsinfo  ${DIM}(SSH-Befehl / RDP + Passwort)${NC}"
    echo -e "  ${CYAN}[0]${NC} Zurueck"
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
    read -rp "Auswahl: " CHOICE

    case "$CHOICE" in
        1) clear; list_instances; read -rp "Enter zum Fortfahren..." ;;
        2) create_instance; read -rp "Enter zum Fortfahren..." ;;
        3) toggle_instance; read -rp "Enter zum Fortfahren..." ;;
        4) terminate_instance; read -rp "Enter zum Fortfahren..." ;;
        5) connection_info; read -rp "Enter zum Fortfahren..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ungueltige Auswahl.${NC}"; sleep 1 ;;
    esac
done
