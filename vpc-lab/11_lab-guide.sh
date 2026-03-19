#!/bin/bash

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

clear
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           AWS VPC Lab – Schritt-Anleitung       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BOLD}─── Schritt 1: Vorbereitung ─────────────────────────${NC}"
echo -e "  1. AWS Academy Credentials aktualisieren"
echo -e "     ${DIM}→ Menue [1]${NC}"
echo -e "  2. Region und Key-Name einstellen"
echo -e "     ${DIM}→ Menue [2]${NC}"
echo -e "  3. Key Pair erstellen oder vorhandenes auswaehlen"
echo -e "     ${DIM}→ Menue [3]  ·  00_create-keypair.sh${NC}"
echo ""

echo -e "${BOLD}─── Schritt 2: Netzwerk aufbauen ────────────────────${NC}"
echo -e "  4. VPC anlegen mit CIDR-Block (z.B. 10.0.0.0/16)"
echo -e "  5. Subnetze definieren: public und/oder private"
echo -e "  6. Internet Gateway erstellen und an VPC haengen"
echo -e "  7. Route Table fuer public Subnetz auf IGW setzen"
echo -e "  8. Security Groups pro Subnetz konfigurieren (Port 22, 80)"
echo -e "     ${DIM}→ Menue [5]  ·  01_vpc-setup.sh${NC}"
echo ""

echo -e "${BOLD}─── Schritt 3: EC2 Instanzen starten ───────────────${NC}"
echo -e "  9.  Je eine Instanz pro Subnetz starten"
echo -e "  10. Instance Type, AMI (Amazon Linux 2) und Key Pair angeben"
echo -e "  11. HTTP-Antworttext festlegen (wird per User-Data geladen)"
echo -e "  12. Warten bis Instanzen laufen (~2 Minuten)"
echo -e "      ${DIM}→ Menue [6]  ·  02_ec2-setup.sh${NC}"
echo ""

echo -e "${BOLD}─── Schritt 4: Verbindung pruefen ───────────────────${NC}"
echo -e "  13. Public IPs und Status abrufen"
echo -e "      ${DIM}→ Menue [11]  ·  03_get-ips.sh${NC}"
echo -e "  14. SSH-Zugriff testen:"
echo -e "      ${CYAN}ssh -i <key>.pem ec2-user@<PUBLIC_IP>${NC}"
echo -e "  15. HTTP-Antwort pruefen:"
echo -e "      ${CYAN}curl http://<PUBLIC_IP>${NC}  →  'Hello public' erwartet"
echo ""

echo -e "${BOLD}─── Schritt 5: Netzwerk absichern (optional) ────────${NC}"
echo -e "  16. Security Group Regeln anpassen (Ports oeffnen/sperren)"
echo -e "      ${DIM}→ Menue [9]  ·  08_security-groups.sh${NC}"
echo -e "  17. Network ACLs auf Subnetz-Ebene pruefen oder aendern"
echo -e "      ${DIM}→ Menue [10]  ·  09_network-acl.sh${NC}"
echo ""

echo -e "${BOLD}─── Schritt 6: Aufraumen ────────────────────────────${NC}"
echo -e "  18. Alle Ressourcen loeschen (Instanzen, SGs, Subnetze, VPC)"
echo -e "      ${DIM}→ Menue [15]  ·  05_teardown.sh${NC}"
echo ""

echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
read -rp "Enter druecken um zurueckzukehren..."
