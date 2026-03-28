#!/bin/bash

# SSH-Tunnel: PEM kopieren + Verbindungsbefehle anzeigen

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${BOLD}=== SSH-Tunnel & PEM-Übertragung ===${NC}"
echo ""

# ─── Konfiguration laden ──────────────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/02_output.env" ]; then
    echo -e "${RED}Fehler: 02_output.env nicht gefunden. Bitte zuerst EC2-Setup ausfuehren.${NC}"
    exit 1
fi
source "$SCRIPT_DIR/01_output.env"
source "$SCRIPT_DIR/02_output.env"

PEM_PATH="$SCRIPT_DIR/${KEY_NAME}.pem"
if [ ! -f "$PEM_PATH" ]; then
    echo -e "${RED}Fehler: PEM-Datei '$PEM_PATH' nicht gefunden.${NC}"
    exit 1
fi

# ─── IPs abrufen ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}Instanz-IPs abrufen...${NC}"
echo ""

PUBLIC_INSTANCE_ID=""
PUBLIC_SN_NAME=""
PRIVATE_INSTANCE_ID=""

for ((n=1; n<=SUBNET_COUNT; n++)); do
    SN_TYPE_VAR="SN_TYPE_$n"
    SN_NAME_VAR="SN_NAME_$n"
    IID_VAR="INSTANCE_ID_$n"
    if [ "${!SN_TYPE_VAR}" == "public" ] && [ -z "$PUBLIC_INSTANCE_ID" ]; then
        PUBLIC_INSTANCE_ID="${!IID_VAR}"
        PUBLIC_SN_NAME="${!SN_NAME_VAR}"
    elif [ "${!SN_TYPE_VAR}" == "private" ] && [ -z "$PRIVATE_INSTANCE_ID" ]; then
        PRIVATE_INSTANCE_ID="${!IID_VAR}"
    fi
done

if [ -z "$PUBLIC_INSTANCE_ID" ]; then
    echo -e "${RED}Keine public Instanz gefunden.${NC}"; exit 1
fi

# Public IP + Private IP der Public-Instanz
RESULT=$(aws ec2 describe-instances --instance-ids "$PUBLIC_INSTANCE_ID" \
    --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress]" \
    --output text --region "$REGION" 2>/dev/null)
STATE=$(echo "$RESULT" | awk '{print $1}')
PUB_IP=$(echo "$RESULT" | awk '{print $2}')
[ "$PUB_IP" == "None" ] && PUB_IP=""

echo -e "  ec2-${PUBLIC_SN_NAME}: State=${CYAN}${STATE}${NC}  PublicIP=${CYAN}${PUB_IP:--}${NC}"

# Private IP der privaten Instanz
PRIV_IP_TARGET=""
if [ -n "$PRIVATE_INSTANCE_ID" ]; then
    PRIV_IP_TARGET=$(aws ec2 describe-instances --instance-ids "$PRIVATE_INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text --region "$REGION" 2>/dev/null)
    [ "$PRIV_IP_TARGET" == "None" ] && PRIV_IP_TARGET=""
    echo -e "  ec2-private:         PrivateIP=${CYAN}${PRIV_IP_TARGET:--}${NC}"
fi

if [ -z "$PUB_IP" ]; then
    echo ""
    echo -e "${RED}Public IP noch nicht verfuegbar. Instanz laeuft noch nicht.${NC}"
    exit 1
fi

# ─── PEM kopieren ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── PEM auf Public Instanz kopieren ─────────────────${NC}"
echo ""
read -rp "PEM jetzt uebertragen? [J/n]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Nn]$ ]]; then
    scp -i "$PEM_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        "$PEM_PATH" "ec2-user@${PUB_IP}:~/${KEY_NAME}.pem" 2>/dev/null
    if [ $? -eq 0 ]; then
        ssh -i "$PEM_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "ec2-user@${PUB_IP}" "chmod 400 ~/${KEY_NAME}.pem" 2>/dev/null
        echo -e "  ${GREEN}✓ ${KEY_NAME}.pem erfolgreich uebertragen und chmod 400 gesetzt${NC}"
    else
        echo -e "  ${RED}✗ SCP fehlgeschlagen – manuell:${NC}"
        echo -e "  ${CYAN}scp -i $PEM_PATH $PEM_PATH ec2-user@${PUB_IP}:~/${NC}"
    fi
fi

# ─── Verbindungsbefehle ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}─── Verbindungsbefehle ──────────────────────────────${NC}"
echo ""
echo -e "  ${BOLD}Schritt 1 – Von deinem Mac: SSH auf Public Instanz${NC}"
echo ""
echo -e "      ${CYAN}ssh -i $PEM_PATH ec2-user@${PUB_IP}${NC}"

if [ -n "$PRIV_IP_TARGET" ]; then
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Schritt 2 – Auf der Public Instanz: Tunnel zur Private starten${NC}"
    echo -e "  ${DIM}(Port 4747 muss in Public SG offen sein)${NC}"
    echo ""
    echo -e "      ${CYAN}ssh -i ~/${KEY_NAME}.pem -L 0.0.0.0:4747:${PRIV_IP_TARGET}:80 ec2-user@${PRIV_IP_TARGET} -N${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Schritt 3 – Von deinem Mac: Testen${NC}"
    echo ""
    echo -e "      ${CYAN}curl http://${PUB_IP}:4747${NC}"
    echo -e "      ${DIM}→ erwartet: Hallo, ich bin eine private Instanz${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Optional – Direkt auf Private springen (von Public):${NC}"
    echo ""
    echo -e "      ${CYAN}ssh -i ~/${KEY_NAME}.pem ec2-user@${PRIV_IP_TARGET}${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Tunnel beenden (auf Public Instanz):${NC}"
    echo ""
    echo -e "      ${CYAN}ssh -i $PEM_PATH ec2-user@${PUB_IP} \"kill \\\$(lsof -ti:4747)\"${NC}"

    echo ""
    echo -e "  ════════════════════════════════════════════════"
    echo -e "  ${BOLD}Reverse Tunnel – Private baut Verbindung zur Public${NC}"
    echo -e "  ════════════════════════════════════════════════"
    echo ""
    echo -e "  ${DIM}Nutze diesen Tunnel wenn die Private Instanz kein Internet Gateway hat${NC}"
    echo -e "  ${DIM}und trotzdem von aussen erreichbar sein soll.${NC}"
    echo ""
    echo -e "  ${BOLD}Schritt 1 – GatewayPorts auf Public Instanz aktivieren${NC}"
    echo -e "  ${DIM}(einmalig – erlaubt Reverse Tunnel auf 0.0.0.0 statt nur localhost)${NC}"
    echo ""
    echo -e "      ${CYAN}ssh -i $PEM_PATH ec2-user@${PUB_IP}${NC}"
    echo -e "      ${CYAN}echo 'GatewayPorts yes' | sudo tee -a /etc/ssh/sshd_config${NC}"
    echo -e "      ${CYAN}sudo systemctl restart sshd${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Schritt 2 – Mac → Public → Private mit Agent Forwarding${NC}"
    echo -e "  ${DIM}(-A leitet deinen lokalen Key weiter – kein PEM auf den Instanzen noetig)${NC}"
    echo ""
    echo -e "  ${DIM}Mac:${NC}"
    echo -e "      ${CYAN}ssh -A -i $PEM_PATH ec2-user@${PUB_IP}${NC}"
    echo ""
    echo -e "  ${DIM}Auf Public Instanz:${NC}"
    echo -e "      ${CYAN}ssh -A ec2-user@${PRIV_IP_TARGET}${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Schritt 3 – Auf der Private Instanz: Reverse Tunnel starten${NC}"
    echo -e "  ${RED}WICHTIG: Dieser Befehl muss auf der PRIVATE Instanz ausgefuehrt werden!${NC}"
    echo -e "  ${DIM}(ohne -i, da Agent Forwarding den Key bereitstellt)${NC}"
    echo ""
    echo -e "      ${CYAN}ssh -R 0.0.0.0:5858:localhost:80 ec2-user@${PUB_IP} -N${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Schritt 4 – Von deinem Mac: Testen${NC}"
    echo ""
    echo -e "      ${CYAN}curl http://${PUB_IP}:5858${NC}"
    echo -e "      ${DIM}→ erwartet: Antwort der privaten Instanz${NC}"
    echo -e "      ${DIM}  (bei 'Hallo public': Tunnel laeuft auf falscher Maschine!)${NC}"
    echo ""
    echo -e "  ────────────────────────────────────────────────"
    echo -e "  ${BOLD}Reverse Tunnel beenden (auf Private Instanz):${NC}"
    echo ""
    echo -e "      ${CYAN}kill \$(lsof -ti:5858)${NC}"
    echo ""
    echo -e "  ${DIM}Vergleich:${NC}"
    echo -e "    ${DIM}Forward:  Mac → Public:4747 → Private:80  (Public initiiert)${NC}"
    echo -e "    ${DIM}Reverse:  Private → Public:5858 ← Mac     (Private initiiert)${NC}"
fi
echo ""
