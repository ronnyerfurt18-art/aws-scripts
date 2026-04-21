#!/bin/bash
# ============================================================
#  API-Labor — Interaktiver REST-API Request Builder
#  Baut curl-Befehle interaktiv auf und führt sie aus.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

separator() { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }
step()      { echo -e "\n${BOLD}${CYAN}$1${NC}"; }
ask()       { read -rp "$(echo -e "  ${YELLOW}$1${NC} ")" "$2"; }
ask_lower() { read -rp "$(echo -e "  ${YELLOW}$1${NC} ")" "$2"
              eval "$2=\${$2,,}"; }

# ──────────────────────────────────────────────────────────────
#  JSON-Hilfsfunktionen
# ──────────────────────────────────────────────────────────────

# Escaped einen String für JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Gibt einen JSON-Wert zurück (string oder number/bool/null unquoted)
json_value() {
    local v="$1"
    # Zahl, bool oder null → kein Anführungszeichen
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || \
       [[ "$v" == "true" || "$v" == "false" || "$v" == "null" ]]; then
        printf '%s' "$v"
    else
        printf '"%s"' "$(json_escape "$v")"
    fi
}

# Fragt Parameter ab und baut einen JSON-Body oder Query-String
# Modus: "json" → JSON-Object | "query" → key=val&key=val
build_params() {
    local mode="$1"          # "json" oder "query"
    local -a json_parts=()
    local query_str=""
    local more="j"

    while [[ "$more" == "j" || "$more" == "ja" || "$more" == "y" || "$more" == "yes" ]]; do
        echo ""
        ask "Parameter-Name:" PARAM_NAME
        [ -z "$PARAM_NAME" ] && break

        echo -e "  ${DIM}Typ wählen:${NC}"
        echo -e "    ${CYAN}[1]${NC} Einfacher Wert  (z.B. \"max\", 42, true)"
        echo -e "    ${CYAN}[2]${NC} Objekt          (z.B. {\"city\":\"Berlin\"})"
        echo -e "    ${CYAN}[3]${NC} Array           (z.B. [\"a\",\"b\",\"c\"])"
        ask "Typ [1/2/3]:" PARAM_TYPE

        case "$PARAM_TYPE" in
            1)
                ask "Wert:" PARAM_VAL
                if [ "$mode" == "json" ]; then
                    json_parts+=("\"$PARAM_NAME\": $(json_value "$PARAM_VAL")")
                else
                    query_str+="${query_str:+&}${PARAM_NAME}=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PARAM_VAL'))" 2>/dev/null || echo "$PARAM_VAL")"
                fi
                ;;

            2)
                echo -e "  ${DIM}Objekt-Felder eingeben (leer lassen zum Beenden):${NC}"
                local -a obj_parts=()
                while true; do
                    ask "  Feld-Name (leer = fertig):" OBJ_KEY
                    [ -z "$OBJ_KEY" ] && break
                    ask "  Feld-Wert:" OBJ_VAL
                    obj_parts+=("\"$OBJ_KEY\": $(json_value "$OBJ_VAL")")
                done
                local obj_json="{$(IFS=', '; echo "${obj_parts[*]}")}"
                if [ "$mode" == "json" ]; then
                    json_parts+=("\"$PARAM_NAME\": $obj_json")
                else
                    query_str+="${query_str:+&}${PARAM_NAME}=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$obj_json'))" 2>/dev/null || echo "$obj_json")"
                fi
                ;;

            3)
                echo -e "  ${DIM}Array-Elemente eingeben (leer lassen zum Beenden):${NC}"
                local -a arr_items=()
                local idx=1
                while true; do
                    ask "  Element $idx (leer = fertig):" ARR_ITEM
                    [ -z "$ARR_ITEM" ] && break
                    arr_items+=("$(json_value "$ARR_ITEM")")
                    (( idx++ ))
                done
                local arr_json="[$(IFS=', '; echo "${arr_items[*]}")]"
                if [ "$mode" == "json" ]; then
                    json_parts+=("\"$PARAM_NAME\": $arr_json")
                else
                    query_str+="${query_str:+&}${PARAM_NAME}=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$arr_json'))" 2>/dev/null || echo "$arr_json")"
                fi
                ;;

            *)
                echo -e "  ${RED}Ungültiger Typ — übersprungen.${NC}"
                ;;
        esac

        echo ""
        ask_lower "Weiteren Parameter hinzufügen? [j/N]:" more
    done

    if [ "$mode" == "json" ]; then
        if [ ${#json_parts[@]} -eq 0 ]; then
            BUILT_PARAMS=""
        else
            BUILT_PARAMS="{$(IFS=$',\n  '; printf '  %s,\n' "${json_parts[@]}"; )}"
            # Sauber formatieren
            local joined
            joined=$(IFS=', '; echo "${json_parts[*]}")
            BUILT_PARAMS="{$joined}"
        fi
    else
        BUILT_PARAMS="$query_str"
    fi
}

# ──────────────────────────────────────────────────────────────
#  Hauptprogramm
# ──────────────────────────────────────────────────────────────
main() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║      API-Labor — REST Request Builder            ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${DIM}Baut einen curl-Befehl auf und führt ihn aus.${NC}"
        separator

        # ── 1. Methode ────────────────────────────────────────
        step "[1] HTTP-Methode"
        echo -e "    ${CYAN}[1]${NC} GET    ${CYAN}[2]${NC} POST   ${CYAN}[3]${NC} PUT"
        echo -e "    ${CYAN}[4]${NC} PATCH  ${CYAN}[5]${NC} DELETE"
        ask "Auswahl [1-5]:" METHOD_CHOICE
        case "$METHOD_CHOICE" in
            1) METHOD="GET"    ;;
            2) METHOD="POST"   ;;
            3) METHOD="PUT"    ;;
            4) METHOD="PATCH"  ;;
            5) METHOD="DELETE" ;;
            *) echo -e "  ${RED}Ungültige Auswahl — GET wird verwendet.${NC}"; METHOD="GET" ;;
        esac
        echo -e "  ${GREEN}✓ Methode: $METHOD${NC}"

        # ── 2. URL ────────────────────────────────────────────
        step "[2] Ziel-URL"
        ask "URL (z.B. https://api.example.com/users):" BASE_URL
        if [ -z "$BASE_URL" ]; then
            echo -e "  ${RED}Keine URL eingegeben — Abbruch.${NC}"; echo ""
            ask_lower "Neu starten? [j/N]:" RESTART
            [[ "$RESTART" == "j" || "$RESTART" == "ja" ]] && continue || break
        fi
        echo -e "  ${GREEN}✓ URL: $BASE_URL${NC}"

        # ── 3. Authorization-Header ───────────────────────────
        step "[3] Authorization-Header"
        ask_lower "Wird ein Authorization-Header benötigt? [j/N]:" NEED_AUTH
        AUTH_HEADER=""
        if [[ "$NEED_AUTH" == "j" || "$NEED_AUTH" == "ja" ]]; then
            echo -e "  ${DIM}Format-Optionen:${NC}"
            echo -e "    ${CYAN}[1]${NC} Bearer <token>"
            echo -e "    ${CYAN}[2]${NC} Basic <credentials>"
            echo -e "    ${CYAN}[3]${NC} Eigenes Format"
            ask "Format [1/2/3]:" AUTH_TYPE
            case "$AUTH_TYPE" in
                1) ask "Token eingeben:" TOKEN_VAL
                   AUTH_HEADER="Authorization: Bearer $TOKEN_VAL" ;;
                2) ask "Credentials eingeben:" TOKEN_VAL
                   AUTH_HEADER="Authorization: Basic $TOKEN_VAL" ;;
                3) ask "Vollständiger Header-Wert (z.B. ApiKey abc123):" TOKEN_VAL
                   AUTH_HEADER="Authorization: $TOKEN_VAL" ;;
                *) ask "Token eingeben:" TOKEN_VAL
                   AUTH_HEADER="Authorization: Bearer $TOKEN_VAL" ;;
            esac
            echo -e "  ${GREEN}✓ Header gesetzt${NC}"
        fi

        # ── 4. Weitere Header ─────────────────────────────────
        step "[4] Weitere Header"
        ask_lower "Weitere Header hinzufügen? [j/N]:" NEED_HEADERS
        EXTRA_HEADERS=()
        while [[ "$NEED_HEADERS" == "j" || "$NEED_HEADERS" == "ja" ]]; do
            ask "Header-Name:" H_NAME
            ask "Header-Wert:" H_VAL
            EXTRA_HEADERS+=("$H_NAME: $H_VAL")
            echo -e "  ${GREEN}✓ $H_NAME: $H_VAL${NC}"
            ask_lower "Noch ein Header? [j/N]:" NEED_HEADERS
        done

        # ── 5. Parameter ──────────────────────────────────────
        step "[5] Parameter"
        QUERY_STRING=""
        JSON_BODY=""

        if [[ "$METHOD" == "GET" || "$METHOD" == "DELETE" ]]; then
            ask_lower "URL-Parameter hinzufügen? [j/N]:" NEED_PARAMS
            if [[ "$NEED_PARAMS" == "j" || "$NEED_PARAMS" == "ja" ]]; then
                build_params "query"
                QUERY_STRING="$BUILT_PARAMS"
                [ -n "$QUERY_STRING" ] && echo -e "  ${GREEN}✓ Query: ?$QUERY_STRING${NC}"
            fi
        else
            ask_lower "JSON-Body-Parameter hinzufügen? [j/N]:" NEED_PARAMS
            if [[ "$NEED_PARAMS" == "j" || "$NEED_PARAMS" == "ja" ]]; then
                build_params "json"
                JSON_BODY="$BUILT_PARAMS"
                [ -n "$JSON_BODY" ] && echo -e "  ${GREEN}✓ Body: $JSON_BODY${NC}"
            fi
        fi

        # ── Befehl zusammenbauen ──────────────────────────────
        FINAL_URL="$BASE_URL"
        [ -n "$QUERY_STRING" ] && FINAL_URL="${BASE_URL}?${QUERY_STRING}"

        CMD="curl -s -X $METHOD"
        [ -n "$AUTH_HEADER"   ] && CMD+=" \\\n     -H \"$AUTH_HEADER\""
        for h in "${EXTRA_HEADERS[@]}"; do
            CMD+=" \\\n     -H \"$h\""
        done
        if [ -n "$JSON_BODY" ]; then
            CMD+=" \\\n     -H \"Content-Type: application/json\""
            CMD+=" \\\n     -d '$JSON_BODY'"
        fi
        CMD+=" \\\n     \"$FINAL_URL\""

        # ── Anzeigen ──────────────────────────────────────────
        echo ""
        separator
        echo -e "${BOLD}Generierter Befehl:${NC}"
        echo ""
        echo -e "${CYAN}$(echo -e "$CMD")${NC}"
        separator

        # ── Ausführen ─────────────────────────────────────────
        ask_lower "Anfrage jetzt ausführen? [J/n]:" DO_RUN
        if [[ "$DO_RUN" != "n" && "$DO_RUN" != "nein" ]]; then
            echo ""
            echo -e "${BOLD}Antwort:${NC}"
            echo ""

            # Befehl als Array für sicheres exec aufbauen
            CURL_CMD=(curl -s -X "$METHOD")
            [ -n "$AUTH_HEADER" ] && CURL_CMD+=(-H "$AUTH_HEADER")
            for h in "${EXTRA_HEADERS[@]}"; do
                CURL_CMD+=(-H "$h")
            done
            if [ -n "$JSON_BODY" ]; then
                CURL_CMD+=(-H "Content-Type: application/json")
                CURL_CMD+=(-d "$JSON_BODY")
            fi
            CURL_CMD+=("$FINAL_URL")

            # Ausführen + JSON pretty-print falls möglich
            RESPONSE=$("${CURL_CMD[@]}" 2>&1)
            HTTP_CODE=$("${CURL_CMD[@]}" -o /dev/null -w "%{http_code}" 2>/dev/null)

            # Statuscode färben
            if [[ "$HTTP_CODE" =~ ^2 ]]; then
                echo -e "  ${GREEN}HTTP $HTTP_CODE${NC}"
            elif [[ "$HTTP_CODE" =~ ^4 ]]; then
                echo -e "  ${RED}HTTP $HTTP_CODE${NC}"
            elif [[ "$HTTP_CODE" =~ ^5 ]]; then
                echo -e "  ${RED}HTTP $HTTP_CODE${NC}"
            else
                echo -e "  ${YELLOW}HTTP $HTTP_CODE${NC}"
            fi
            echo ""

            # Response ausgeben (JSON formatieren falls möglich)
            if command -v python3 &>/dev/null; then
                PRETTY=$(echo "$RESPONSE" | python3 -m json.tool 2>/dev/null)
                if [ -n "$PRETTY" ]; then
                    echo -e "${GREEN}$PRETTY${NC}"
                else
                    echo -e "${NC}$RESPONSE${NC}"
                fi
            else
                echo "$RESPONSE"
            fi
        fi

        # ── Neu starten oder beenden ──────────────────────────
        echo ""
        separator
        ask_lower "Neue Anfrage stellen? [j/N]:" AGAIN
        [[ "$AGAIN" == "j" || "$AGAIN" == "ja" ]] || break
    done

    echo ""
    echo -e "${GREEN}Tschüss!${NC}"
    echo ""
}

main
