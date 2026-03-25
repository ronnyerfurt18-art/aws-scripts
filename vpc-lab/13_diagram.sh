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

# ─── Subnetze und Instanzen sammeln ──────────────────────────────────────────
declare -a SN_BLOCKS
for ((n=1; n<=SUBNET_COUNT; n++)); do
    NAME_VAR="SN_NAME_$n";   CIDR_VAR="SN_CIDR_$n";   TYPE_VAR="SN_TYPE_$n"
    IID_VAR="INSTANCE_ID_$n"
    SN_BLOCKS[$n]="${!NAME_VAR}|${!CIDR_VAR}|${!TYPE_VAR}|${!IID_VAR}"
done

# ─── Layout berechnen ─────────────────────────────────────────────────────────
CANVAS_W=900
SN_W=220
SN_H=320
SN_START_X=80
SN_Y=120
SN_GAP=60
VPC_PAD=40

TOTAL_SN_W=$(( SUBNET_COUNT * SN_W + (SUBNET_COUNT - 1) * SN_GAP ))
VPC_W=$(( TOTAL_SN_W + 2 * VPC_PAD + SN_START_X - 20 ))
VPC_H=500
IGW_X=$(( VPC_W / 2 - 60 ))
IGW_Y=480

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
<svg width="$(( VPC_W + 100 ))" height="$(( VPC_H + 80 ))" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <marker id="arrow" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#00d4ff"/>
    </marker>
    <marker id="arrow-dashed" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#888"/>
    </marker>
  </defs>

  <!-- VPC -->
  <rect x="20" y="20" width="$VPC_W" height="$VPC_H" rx="16"
        fill="none" stroke="#0f3460" stroke-width="3"/>
  <text x="36" y="46" font-size="15" fill="#aaa" font-family="monospace">VPC</text>
  <text x="70" y="46" font-size="15" fill="#ff6b35" font-weight="bold" font-family="monospace">$VPC_CIDR</text>
  <text x="36" y="64" font-size="11" fill="#555" font-family="monospace">$VPC_ID</text>

  <!-- AZ -->
  <rect x="40" y="80" width="$(( VPC_W - 40 ))" height="$(( VPC_H - 120 ))" rx="10"
        fill="none" stroke="#ff6b35" stroke-width="2" stroke-dasharray="10,5"/>
  <text x="56" y="100" font-size="12" fill="#ff6b35" font-family="monospace">AZ: ${REGION}a</text>

HTMLEOF

# ─── Subnetze zeichnen ────────────────────────────────────────────────────────
for ((n=1; n<=SUBNET_COUNT; n++)); do
    IFS='|' read -r SN_NAME SN_CIDR SN_TYPE SN_IID <<< "${SN_BLOCKS[$n]}"
    X=$(( SN_START_X + (n-1) * (SN_W + SN_GAP) + 20 ))
    Y=$SN_Y

    # Farben je Typ
    case "$SN_TYPE" in
        public)  BORDER="#00d4ff"; LABEL_COLOR="#00d4ff"; TYPE_LABEL="Public" ;;
        private) BORDER="#ff4757"; LABEL_COLOR="#ff4757"; TYPE_LABEL="Private" ;;
        *)       BORDER="#888";    LABEL_COLOR="#888";    TYPE_LABEL="Isoliert" ;;
    esac

    # Subnetz-Box
    cat >> "$OUT_FILE" <<SVGEOF

  <!-- Subnetz $n: $SN_NAME -->
  <rect x="$X" y="$Y" width="$SN_W" height="$SN_H" rx="10"
        fill="#0d1b2a" stroke="$BORDER" stroke-width="2"/>
  <text x="$(( X + 10 ))" y="$(( Y + 22 ))" font-size="13" fill="$LABEL_COLOR" font-weight="bold" font-family="monospace">$SN_NAME</text>
  <text x="$(( X + 10 ))" y="$(( Y + 38 ))" font-size="10" fill="#888" font-family="monospace">$SN_CIDR  [$TYPE_LABEL]</text>

  <!-- EC2 -->
  <rect x="$(( X + 20 ))" y="$(( Y + 52 ))" width="$(( SN_W - 40 ))" height="48" rx="6"
        fill="#1a3a5c" stroke="$BORDER" stroke-width="1.5"/>
  <text x="$(( X + SN_W/2 ))" y="$(( Y + 72 ))" font-size="11" fill="#fff" text-anchor="middle" font-family="monospace">EC2</text>
  <text x="$(( X + SN_W/2 ))" y="$(( Y + 88 ))" font-size="10" fill="#aaa" text-anchor="middle" font-family="monospace">ec2-$SN_NAME</text>

  <!-- SG -->
  <rect x="$(( X + SN_W - 55 ))" y="$(( Y + 52 ))" width="40" height="20" rx="4"
        fill="#2d1b4e" stroke="#9b59b6" stroke-width="1"/>
  <text x="$(( X + SN_W - 35 ))" y="$(( Y + 66 ))" font-size="9" fill="#9b59b6" text-anchor="middle" font-family="monospace">SG</text>

  <!-- RT -->
  <circle cx="$(( X + 30 ))" cy="$(( Y + 200 ))" r="28" fill="#0d1b2a" stroke="#00d4ff" stroke-width="2"/>
  <text x="$(( X + 30 ))" y="$(( Y + 205 ))" font-size="13" fill="#00d4ff" text-anchor="middle" font-weight="bold" font-family="monospace">RT</text>

  <!-- ACL -->
  <rect x="$(( X + SN_W - 60 ))" y="$(( Y + 140 ))" width="48" height="30" rx="4"
        fill="#0d1b2a" stroke="#2ecc71" stroke-width="1.5"/>
  <text x="$(( X + SN_W - 36 ))" y="$(( Y + 160 ))" font-size="10" fill="#2ecc71" text-anchor="middle" font-family="monospace">ACL</text>

  <!-- Verbindung EC2 → RT -->
  <line x1="$(( X + SN_W/2 ))" y1="$(( Y + 100 ))" x2="$(( X + 30 ))" y2="$(( Y + 172 ))"
        stroke="#00d4ff" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- SG Label -->
  <text x="$(( X + 10 ))" y="$(( Y + 310 ))" font-size="10" fill="#9b59b6" font-family="monospace">sec-$SN_NAME</text>
  <text x="$(( X + 10 ))" y="$(( Y + 325 ))" font-size="10" fill="#00d4ff" font-family="monospace">rt-$SN_NAME</text>

SVGEOF
done

# ─── IGW ──────────────────────────────────────────────────────────────────────
cat >> "$OUT_FILE" <<SVGEOF

  <!-- Internet Gateway -->
  <rect x="$IGW_X" y="$IGW_Y" width="120" height="44" rx="8"
        fill="#0d1b2a" stroke="#00d4ff" stroke-width="2.5"/>
  <text x="$(( IGW_X + 60 ))" y="$(( IGW_Y + 18 ))" font-size="13" fill="#00d4ff" text-anchor="middle" font-weight="bold" font-family="monospace">IGW</text>
  <text x="$(( IGW_X + 60 ))" y="$(( IGW_Y + 34 ))" font-size="9" fill="#555" text-anchor="middle" font-family="monospace">$IGW_ID</text>

  <!-- Internet -->
  <text x="$(( VPC_W + 30 ))" y="$(( VPC_H / 2 ))" font-size="13" fill="#888" text-anchor="middle" font-family="monospace">Internet</text>
  <line x1="$(( VPC_W + 20 ))" y1="$(( VPC_H / 2 + 10 ))" x2="$(( VPC_W + 20 ))" y2="$(( VPC_H / 2 - 10 ))"
        stroke="#888" stroke-width="1"/>

SVGEOF

# ─── RT → IGW Pfeile für public Subnetze ─────────────────────────────────────
for ((n=1; n<=SUBNET_COUNT; n++)); do
    IFS='|' read -r SN_NAME SN_CIDR SN_TYPE SN_IID <<< "${SN_BLOCKS[$n]}"
    X=$(( SN_START_X + (n-1) * (SN_W + SN_GAP) + 20 ))
    RT_X=$(( X + 30 ))
    RT_Y=$(( SN_Y + 200 ))

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
  <line x1="$(( IGW_X + 120 ))" y1="$(( IGW_Y + 22 ))" x2="$(( VPC_W + 20 ))" y2="$(( VPC_H / 2 ))"
        stroke="#00d4ff" stroke-width="2" marker-end="url(#arrow)"/>

</svg>

<div class="info">
  <b>VPC:</b> <span>$VPC_ID</span> &nbsp;|&nbsp; <b>CIDR:</b> <span>$VPC_CIDR</span> &nbsp;|&nbsp;
  <b>Region:</b> <span>$REGION</span> &nbsp;|&nbsp; <b>IGW:</b> <span>$IGW_ID</span><br>
HTMLEOF

for ((n=1; n<=SUBNET_COUNT; n++)); do
    IFS='|' read -r SN_NAME SN_CIDR SN_TYPE SN_IID <<< "${SN_BLOCKS[$n]}"
    echo "  <b>Subnetz $n:</b> <span>$SN_NAME</span> &nbsp;$SN_CIDR&nbsp; [$SN_TYPE] &nbsp;SG: sec-$SN_NAME &nbsp;RT: rt-$SN_NAME<br>" >> "$OUT_FILE"
done

cat >> "$OUT_FILE" <<HTMLEOF
</div>
</body>
</html>
HTMLEOF

echo -e "${GREEN}✓ Diagramm erstellt:${NC} ${CYAN}$OUT_FILE${NC}"
echo ""
echo -e "Im Browser oeffnen:"
echo -e "  ${CYAN}open $OUT_FILE${NC}"
echo ""

# Automatisch oeffnen
read -rp "Jetzt im Browser oeffnen? [J/n]: " OPEN
[[ ! "$OPEN" =~ ^[Nn]$ ]] && open "$OUT_FILE"
