#!/bin/bash

# VPC-Diagramm als HTML/SVG generieren

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_FILE="$SCRIPT_DIR/vpc-diagram.html"

if [ ! -f "$SCRIPT_DIR/01_output.env" ]; then
    echo -e "${RED}Fehler: 01_output.env nicht gefunden. Bitte zuerst VPC-Setup ausfuehren.${NC}"
    exit 1
fi

source "$SCRIPT_DIR/01_output.env"
[ -f "$SCRIPT_DIR/02_output.env" ] && source "$SCRIPT_DIR/02_output.env"

echo -e "${YELLOW}Generiere VPC-Diagramm...${NC}"

# ─── Load Balancer abfragen ───────────────────────────────────────────────────
LB_RAW=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[].[LoadBalancerName,State.Code,Scheme]" \
    --output text --region "$REGION" 2>/dev/null | head -1)
LB_NAME=$(echo "$LB_RAW" | cut -f1)
LB_STATE=$(echo "$LB_RAW" | cut -f2)
LB_SCHEME=$(echo "$LB_RAW" | cut -f3)

# ─── Subnetze und Instanzen sammeln ──────────────────────────────────────────
declare -a SN_BLOCKS
for ((n=1; n<=SUBNET_COUNT; n++)); do
    NAME_VAR="SN_NAME_$n"; CIDR_VAR="SN_CIDR_$n"; TYPE_VAR="SN_TYPE_$n"
    IID_VAR="INSTANCE_ID_$n"
    SN_BLOCKS[$n]="${!NAME_VAR}|${!CIDR_VAR}|${!TYPE_VAR}|${!IID_VAR}"
done

# ─── Layout berechnen ─────────────────────────────────────────────────────────
SN_W=220
SN_H=340
SN_START_X=80
SN_GAP=60
VPC_PAD=40

# Platz oben für LB falls vorhanden
TOP_OFFSET=0
[ -n "$LB_NAME" ] && TOP_OFFSET=90

TOTAL_SN_W=$(( SUBNET_COUNT * SN_W + (SUBNET_COUNT - 1) * SN_GAP ))
VPC_W=$(( TOTAL_SN_W + 2 * VPC_PAD + SN_START_X - 20 ))
VPC_H=520
VPC_Y=$(( 20 + TOP_OFFSET ))
SN_Y=$(( VPC_Y + 100 ))
IGW_X=$(( VPC_W / 2 - 60 ))
IGW_Y=$(( VPC_Y + VPC_H - 44 ))
SVG_W=$(( VPC_W + 120 ))
SVG_H=$(( VPC_Y + VPC_H + 60 ))

LB_X=$(( VPC_W / 2 - 60 ))
LB_Y=12
LB_W=120
LB_H=44

# ─── HTML generieren ─────────────────────────────────────────────────────────
cat > "$OUT_FILE" <<HTMLEOF
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<title>VPC Diagramm – $VPC_ID</title>
<style>
  body { font-family: monospace; background: #1a1a2e; color: #eee; margin: 20px; }
  h2   { color: #00d4ff; }
  svg  { background: #16213e; border-radius: 12px; border: 1px solid #0f3460; }
  .info { margin-top: 16px; background: #0f3460; padding: 12px 20px; border-radius: 8px; font-size: 13px; line-height: 1.8; }
  .info span { color: #00d4ff; }
</style>
</head>
<body>
<h2>VPC-Diagramm</h2>
<svg width="$SVG_W" height="$SVG_H" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <marker id="arrow" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#00d4ff"/>
    </marker>
    <marker id="arrow-dashed" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#888"/>
    </marker>
  </defs>

  <!-- VPC -->
  <rect x="20" y="$VPC_Y" width="$VPC_W" height="$VPC_H" rx="16"
        fill="none" stroke="#0f3460" stroke-width="3"/>
  <text x="36" y="$(( VPC_Y + 26 ))" font-size="15" fill="#aaa" font-family="monospace">VPC</text>
  <text x="70" y="$(( VPC_Y + 26 ))" font-size="15" fill="#ff6b35" font-weight="bold" font-family="monospace">$VPC_CIDR</text>
  <text x="36" y="$(( VPC_Y + 44 ))" font-size="11" fill="#555" font-family="monospace">$VPC_ID</text>

  <!-- AZ -->
  <rect x="40" y="$(( VPC_Y + 60 ))" width="$(( VPC_W - 40 ))" height="$(( VPC_H - 120 ))" rx="10"
        fill="none" stroke="#ff6b35" stroke-width="2" stroke-dasharray="10,5"/>
  <text x="56" y="$(( VPC_Y + 80 ))" font-size="12" fill="#ff6b35" font-family="monospace">AZ: ${REGION}a / ${REGION}b</text>

HTMLEOF

# ─── Load Balancer zeichnen (falls vorhanden) ──────────────────────────────────
if [ -n "$LB_NAME" ]; then
    [ "$LB_STATE" == "active" ] && LB_COLOR="#00d4ff" || LB_COLOR="#888"
    cat >> "$OUT_FILE" <<SVGEOF

  <!-- Load Balancer -->
  <rect x="$LB_X" y="$LB_Y" width="$LB_W" height="$LB_H" rx="8"
        fill="#0d2a1a" stroke="$LB_COLOR" stroke-width="2.5"/>
  <text x="$(( LB_X + LB_W/2 ))" y="$(( LB_Y + 16 ))" font-size="11" fill="$LB_COLOR" text-anchor="middle" font-weight="bold" font-family="monospace">ALB</text>
  <text x="$(( LB_X + LB_W/2 ))" y="$(( LB_Y + 30 ))" font-size="9" fill="#aaa" text-anchor="middle" font-family="monospace">$LB_NAME</text>
  <text x="$(( LB_X + LB_W/2 ))" y="$(( LB_Y + 42 ))" font-size="8" fill="#555" text-anchor="middle" font-family="monospace">$LB_SCHEME</text>

  <!-- Internet → ALB -->
  <text x="$(( SVG_W - 50 ))" y="$(( LB_Y + 22 ))" font-size="12" fill="#888" text-anchor="middle" font-family="monospace">Internet</text>
  <line x1="$(( LB_X + LB_W ))" y1="$(( LB_Y + LB_H/2 ))" x2="$(( SVG_W - 80 ))" y2="$(( LB_Y + LB_H/2 ))"
        stroke="#00d4ff" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- ALB → IGW (Pfeil nach unten) -->
  <line x1="$(( LB_X + LB_W/2 ))" y1="$(( LB_Y + LB_H ))" x2="$(( IGW_X + 60 ))" y2="$IGW_Y"
        stroke="$LB_COLOR" stroke-width="1.5" stroke-dasharray="6,3" marker-end="url(#arrow)"/>

SVGEOF
fi

# ─── Subnetze zeichnen ────────────────────────────────────────────────────────
for ((n=1; n<=SUBNET_COUNT; n++)); do
    IFS='|' read -r SN_NAME SN_CIDR SN_TYPE SN_IID <<< "${SN_BLOCKS[$n]}"
    X=$(( SN_START_X + (n-1) * (SN_W + SN_GAP) + 20 ))
    Y=$SN_Y

    case "$SN_TYPE" in
        public)  BORDER="#00d4ff"; LABEL_COLOR="#00d4ff"; TYPE_LABEL="Public" ;;
        private) BORDER="#ff4757"; LABEL_COLOR="#ff4757"; TYPE_LABEL="Private" ;;
        *)       BORDER="#888";    LABEL_COLOR="#888";    TYPE_LABEL="Isoliert" ;;
    esac

    # SG-Name ermitteln
    SG_NAME_VAR="SN_SG_NAME_$n"
    SG_NAME="${!SG_NAME_VAR:-sec-$SN_NAME}"

    cat >> "$OUT_FILE" <<SVGEOF

  <!-- Subnetz $n: $SN_NAME -->
  <rect x="$X" y="$Y" width="$SN_W" height="$SN_H" rx="10"
        fill="#0d1b2a" stroke="$BORDER" stroke-width="2"/>
  <text x="$(( X + 10 ))" y="$(( Y + 22 ))" font-size="13" fill="$LABEL_COLOR" font-weight="bold" font-family="monospace">$SN_NAME</text>
  <text x="$(( X + 10 ))" y="$(( Y + 38 ))" font-size="10" fill="#888" font-family="monospace">$SN_CIDR  [$TYPE_LABEL]</text>

  <!-- Security Group Rahmen um EC2 -->
  <rect x="$(( X + 14 ))" y="$(( Y + 46 ))" width="$(( SN_W - 28 ))" height="68" rx="5"
        fill="none" stroke="#9b59b6" stroke-width="1.5" stroke-dasharray="5,3"/>
  <text x="$(( X + 18 ))" y="$(( Y + 42 ))" font-size="9" fill="#9b59b6" font-family="monospace">SG: $SG_NAME</text>

  <!-- EC2 -->
  <rect x="$(( X + 22 ))" y="$(( Y + 54 ))" width="$(( SN_W - 44 ))" height="44" rx="5"
        fill="#1a3a5c" stroke="$BORDER" stroke-width="1.5"/>
  <text x="$(( X + SN_W/2 ))" y="$(( Y + 72 ))" font-size="11" fill="#fff" text-anchor="middle" font-family="monospace">EC2</text>
  <text x="$(( X + SN_W/2 ))" y="$(( Y + 87 ))" font-size="10" fill="#aaa" text-anchor="middle" font-family="monospace">ec2-$SN_NAME</text>

  <!-- RT -->
  <circle cx="$(( X + 36 ))" cy="$(( Y + 210 ))" r="28" fill="#0d1b2a" stroke="#00d4ff" stroke-width="2"/>
  <text x="$(( X + 36 ))" y="$(( Y + 215 ))" font-size="13" fill="#00d4ff" text-anchor="middle" font-weight="bold" font-family="monospace">RT</text>
  <text x="$(( X + 10 ))" y="$(( Y + 250 ))" font-size="9" fill="#00d4ff" font-family="monospace">rt-$SN_NAME</text>

  <!-- ACL -->
  <rect x="$(( X + SN_W - 62 ))" y="$(( Y + 155 ))" width="50" height="30" rx="4"
        fill="#0d1b2a" stroke="#2ecc71" stroke-width="1.5"/>
  <text x="$(( X + SN_W - 37 ))" y="$(( Y + 175 ))" font-size="10" fill="#2ecc71" text-anchor="middle" font-family="monospace">ACL</text>

  <!-- Verbindung EC2 → RT -->
  <line x1="$(( X + SN_W/2 ))" y1="$(( Y + 98 ))" x2="$(( X + 36 ))" y2="$(( Y + 182 ))"
        stroke="#00d4ff" stroke-width="1.5" marker-end="url(#arrow)"/>

SVGEOF
done

# ─── IGW ──────────────────────────────────────────────────────────────────────
cat >> "$OUT_FILE" <<SVGEOF

  <!-- Internet Gateway -->
  <rect x="$IGW_X" y="$IGW_Y" width="120" height="44" rx="8"
        fill="#0d1b2a" stroke="#00d4ff" stroke-width="2.5"/>
  <text x="$(( IGW_X + 60 ))" y="$(( IGW_Y + 18 ))" font-size="13" fill="#00d4ff" text-anchor="middle" font-weight="bold" font-family="monospace">IGW</text>
  <text x="$(( IGW_X + 60 ))" y="$(( IGW_Y + 34 ))" font-size="9" fill="#555" text-anchor="middle" font-family="monospace">$IGW_ID</text>

SVGEOF

# ─── RT → IGW Pfeile ─────────────────────────────────────────────────────────
for ((n=1; n<=SUBNET_COUNT; n++)); do
    IFS='|' read -r SN_NAME SN_CIDR SN_TYPE SN_IID <<< "${SN_BLOCKS[$n]}"
    X=$(( SN_START_X + (n-1) * (SN_W + SN_GAP) + 20 ))
    RT_X=$(( X + 36 ))
    RT_Y=$(( SN_Y + 210 ))

    if [ "$SN_TYPE" == "public" ]; then
        cat >> "$OUT_FILE" <<SVGEOF
  <!-- RT pub → IGW -->
  <line x1="$RT_X" y1="$(( RT_Y + 28 ))" x2="$(( IGW_X + 60 ))" y2="$IGW_Y"
        stroke="#00d4ff" stroke-width="1.5" stroke-dasharray="6,3" marker-end="url(#arrow)"/>
SVGEOF
    else
        cat >> "$OUT_FILE" <<SVGEOF
  <!-- RT priv → IGW (kein Zugang) -->
  <line x1="$RT_X" y1="$(( RT_Y + 28 ))" x2="$(( IGW_X + 60 ))" y2="$IGW_Y"
        stroke="#555" stroke-width="1.5" stroke-dasharray="4,6" marker-end="url(#arrow-dashed)"/>
SVGEOF
    fi
done

# ─── IGW → Internet ───────────────────────────────────────────────────────────
cat >> "$OUT_FILE" <<SVGEOF
  <line x1="$(( IGW_X + 120 ))" y1="$(( IGW_Y + 22 ))" x2="$(( VPC_W + 30 ))" y2="$(( IGW_Y + 22 ))"
        stroke="#00d4ff" stroke-width="2" marker-end="url(#arrow)"/>
  <text x="$(( VPC_W + 40 ))" y="$(( IGW_Y + 18 ))" font-size="12" fill="#888" font-family="monospace">Internet</text>

</svg>
SVGEOF

# ─── Info-Box ─────────────────────────────────────────────────────────────────
cat >> "$OUT_FILE" <<HTMLEOF
<div class="info">
  <b>VPC:</b> <span>$VPC_ID</span> &nbsp;|&nbsp; <b>CIDR:</b> <span>$VPC_CIDR</span> &nbsp;|&nbsp;
  <b>Region:</b> <span>$REGION</span> &nbsp;|&nbsp; <b>IGW:</b> <span>$IGW_ID</span><br>
HTMLEOF

for ((n=1; n<=SUBNET_COUNT; n++)); do
    IFS='|' read -r SN_NAME SN_CIDR SN_TYPE SN_IID <<< "${SN_BLOCKS[$n]}"
    echo "  <b>Subnetz $n:</b> <span>$SN_NAME</span> &nbsp;$SN_CIDR&nbsp; [$SN_TYPE] &nbsp;SG: sec-$SN_NAME &nbsp;RT: rt-$SN_NAME<br>" >> "$OUT_FILE"
done

if [ -n "$LB_NAME" ]; then
    echo "  <b>Load Balancer:</b> <span>$LB_NAME</span> &nbsp;[$LB_SCHEME] &nbsp;Status: $LB_STATE<br>" >> "$OUT_FILE"
fi

cat >> "$OUT_FILE" <<HTMLEOF
</div>
</body>
</html>
HTMLEOF

echo -e "${GREEN}✓ Diagramm erstellt:${NC}"
echo ""
echo -e "  ${CYAN}file://$OUT_FILE${NC}"
echo ""

# Automatisch oeffnen
read -rp "Jetzt im Browser oeffnen? [J/n]: " OPEN
[[ ! "$OPEN" =~ ^[Nn]$ ]] && open "$OUT_FILE"
