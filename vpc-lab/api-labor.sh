#!/bin/bash
# ============================================================
#  API-Labor — REST-API Klausurübung (Terminal-Simulator)
#  Portierung der api-labor-terminal.html nach Bash
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Konfiguration ────────────────────────────────────────────────────────────
BASE_URL="https://api.hochschule-lab.de"
LOGIN="student42"
KURS="webentwicklung2026"

# Fragen: "Fragetext|Antwort1|Antwort2..."
QUESTIONS=(
  "Welcher HTTP-Statuscode bedeutet 'Not Found'?|404"
  "Welches HTTP-Verb wird zum Erstellen neuer Ressourcen verwendet? (nur das Verb)|POST"
  "Welcher Header-Name enthaelt bei einer API ueblicherweise den Token? (nur Name)|Authorization"
  "Was ergibt 7 * 6?|42"
  "Welcher Content-Type-Wert wird fuer JSON verwendet?|application/json"
)

# ─── Zustand ──────────────────────────────────────────────────────────────────
STEP=1
TOKEN=""
QUESTION_TEXT=""
QUESTION_ANSWER=""
AUFGABEN_ID=""

# ─── Ausgabe-Hilfsfunktionen ──────────────────────────────────────────────────
print_prompt() {
    printf "${CYAN}student@api-lab${NC}${YELLOW} ❯${NC} "
}

print_echo() {
    echo -e "${CYAN}student@api-lab${NC}${YELLOW} ❯${NC} $1"
}

http_ok()   { echo -e "  ${GREEN}< HTTP/1.1 200 OK${NC}"; }
http_201()  { echo -e "  ${GREEN}< HTTP/1.1 201 Created${NC}"; }
http_400()  { echo -e "  ${RED}< HTTP/1.1 400 Bad Request${NC}"; }
http_401()  { echo -e "  ${RED}< HTTP/1.1 401 Unauthorized${NC}"; }
http_403()  { echo -e "  ${RED}< HTTP/1.1 403 Forbidden${NC}"; }
http_404()  { echo -e "  ${RED}< HTTP/1.1 404 Not Found${NC}"; }
http_405()  { echo -e "  ${RED}< HTTP/1.1 405 Method Not Allowed${NC}"; }
http_415()  { echo -e "  ${RED}< HTTP/1.1 415 Unsupported Media Type${NC}"; }

json_ok()   { echo -e "  ${GREEN}< $1${NC}"; }
json_err()  { echo -e "  ${RED}< $1${NC}"; }
json_warn() { echo -e "  ${YELLOW}< $1${NC}"; }
hint()      { echo -e "  ${DIM}  Hinweis: $1${NC}"; }

separator() { echo -e "${DIM}────────────────────────────────────────────────────${NC}"; }

# ─── Schritt-Anzeige ──────────────────────────────────────────────────────────
show_steps() {
    echo -n "  "
    if   [ "$STEP" -gt 1 ]; then printf "${GREEN}✓ Token holen${NC}"
    elif [ "$STEP" -eq 1 ]; then printf "${YELLOW}● Token holen${NC}"
    else                          printf "${DIM}○ Token holen${NC}"; fi
    printf "  →  "
    if   [ "$STEP" -gt 2 ]; then printf "${GREEN}✓ Aufgabe laden${NC}"
    elif [ "$STEP" -eq 2 ]; then printf "${YELLOW}● Aufgabe laden${NC}"
    else                          printf "${DIM}○ Aufgabe laden${NC}"; fi
    printf "  →  "
    if   [ "$STEP" -gt 3 ]; then printf "${GREEN}✓ Antwort senden${NC}"
    elif [ "$STEP" -eq 3 ]; then printf "${YELLOW}● Antwort senden${NC}"
    else                          printf "${DIM}○ Antwort senden${NC}"; fi
    echo ""
}

# ─── Fake-Token generieren ────────────────────────────────────────────────────
gen_token() {
    local rand1 rand2
    rand1=$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo "a1b2c3d4")
    rand2=$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo "e5f6g7h8")
    echo "eyJhbGciOiJIUzI1NiJ9.${rand1}${LOGIN}.${rand2}"
}

# ─── curl-Befehl parsen ───────────────────────────────────────────────────────
# Extrahiert: CMD_METHOD, CMD_URL, CMD_PATH, CMD_QUERY_*, CMD_HEADER_*, CMD_BODY
parse_curl() {
    local input="$1"
    CMD_METHOD="GET"
    CMD_URL=""
    CMD_PATH=""
    CMD_BODY=""
    CMD_AUTH_HEADER=""
    CMD_CT_HEADER=""
    CMD_EXPLICIT_METHOD=0

    # Befehl muss mit "curl" anfangen
    local first_word
    first_word=$(echo "$input" | awk '{print $1}')
    if [ "$first_word" != "curl" ]; then
        PARSE_ERROR="Befehl nicht gefunden: '$first_word'. Erwartet: curl …"
        return 1
    fi

    PARSE_ERROR=""

    # Token-Extraktion mit eval (kontrolliert, nur für diese Übung)
    local -a tokens
    eval "tokens=($input)" 2>/dev/null || {
        PARSE_ERROR="Ungültige Anführungszeichen im Befehl."
        return 1
    }

    local i=1
    while [ $i -lt ${#tokens[@]} ]; do
        local tk="${tokens[$i]}"
        case "$tk" in
            -X|--request)
                i=$((i+1))
                CMD_METHOD="${tokens[$i]^^}"
                CMD_EXPLICIT_METHOD=1
                ;;
            -H|--header)
                i=$((i+1))
                local hdr="${tokens[$i]}"
                local hname="${hdr%%:*}"
                local hval="${hdr#*: }"
                case "${hname,,}" in
                    authorization)   CMD_AUTH_HEADER="$hval" ;;
                    content-type)    CMD_CT_HEADER="$hval" ;;
                esac
                ;;
            -d|--data|--data-raw|--data-binary)
                i=$((i+1))
                CMD_BODY="${tokens[$i]}"
                [ $CMD_EXPLICIT_METHOD -eq 0 ] && CMD_METHOD="POST"
                ;;
            -G|--get)
                CMD_METHOD="GET"
                CMD_EXPLICIT_METHOD=1
                ;;
            -s|-v|-i|-L|-k|--silent|--verbose|--include|--location|--insecure)
                ;;  # ignorieren
            -*)
                ;;  # unbekannte Flags ignorieren
            *)
                [ -z "$CMD_URL" ] && CMD_URL="$tk"
                ;;
        esac
        i=$((i+1))
    done

    # URL zerlegen
    if [ -z "$CMD_URL" ]; then
        PARSE_ERROR="Keine URL angegeben."
        return 1
    fi

    # Path extrahieren (ohne Query-String)
    CMD_PATH="${CMD_URL%%\?*}"

    # Query-Parameter
    local qs=""
    if [[ "$CMD_URL" == *"?"* ]]; then
        qs="${CMD_URL#*\?}"
    fi
    CMD_QUERY_LOGIN=""
    CMD_QUERY_KURS=""
    IFS='&' read -ra pairs <<< "$qs"
    for pair in "${pairs[@]}"; do
        local k="${pair%%=*}"
        local v="${pair#*=}"
        case "$k" in
            login) CMD_QUERY_LOGIN="$v" ;;
            kurs)  CMD_QUERY_KURS="$v"  ;;
        esac
    done

    return 0
}

# ─── Server-Simulation: /getToken ────────────────────────────────────────────
server_get_token() {
    # Host prüfen
    if [[ "$CMD_URL" != *"api.hochschule-lab.de"* ]]; then
        echo -e "  ${RED}curl: (6) Could not resolve host: $(echo "$CMD_URL" | sed 's|https\?://||' | cut -d/ -f1)${NC}"
        hint "Die korrekte Basis-URL ist $BASE_URL"
        return
    fi
    if [[ "$CMD_PATH" != *"/getToken"* ]]; then
        http_404; json_err "{ \"error\": \"Endpoint '${CMD_PATH##*/}' existiert nicht. Erwartet: /getToken\" }"
        return
    fi
    if [ "$CMD_METHOD" != "GET" ]; then
        http_405; json_err "{ \"error\": \"Methode $CMD_METHOD nicht erlaubt. /getToken erwartet GET.\" }"
        return
    fi
    if [ -z "$CMD_QUERY_LOGIN" ]; then
        http_400; json_err "{ \"error\": \"Query-Parameter 'login' fehlt.\" }"
        hint "Parameter werden an die URL gehängt, z.B. ?login=...&kurs=..."
        return
    fi
    if [ -z "$CMD_QUERY_KURS" ]; then
        http_400; json_err "{ \"error\": \"Query-Parameter 'kurs' fehlt.\" }"
        return
    fi
    if [ "$CMD_QUERY_LOGIN" != "$LOGIN" ]; then
        http_401; json_err "{ \"error\": \"Unbekannter Login: '$CMD_QUERY_LOGIN'.\" }"
        return
    fi
    if [ "$CMD_QUERY_KURS" != "$KURS" ]; then
        http_403; json_err "{ \"error\": \"Kein Zugriff auf Kurs '$CMD_QUERY_KURS'.\" }"
        return
    fi

    # Erfolg
    TOKEN=$(gen_token)
    http_ok
    echo -e "  ${DIM}< Content-Type: application/json${NC}"
    json_ok "{"
    json_ok "  \"token\": \"$TOKEN\","
    json_ok "  \"expiresIn\": 3600"
    json_ok "}"
    echo ""
    echo -e "  ${GREEN}✓ Token erhalten! Speichere ihn für Schritt 2 + 3.${NC}"
    echo ""
    echo -e "  ${DIM}TOKEN=$TOKEN${NC}"
    STEP=2
}

# ─── Server-Simulation: /getAufgabe ─────────────────────────────────────────
server_get_aufgabe() {
    if [[ "$CMD_URL" != *"api.hochschule-lab.de"* ]]; then
        echo -e "  ${RED}curl: (6) Could not resolve host: $(echo "$CMD_URL" | sed 's|https\?://||' | cut -d/ -f1)${NC}"
        return
    fi
    if [[ "$CMD_PATH" != *"/getAufgabe"* ]]; then
        http_404; json_err "{ \"error\": \"Endpoint '${CMD_PATH##*/}' existiert nicht. Erwartet: /getAufgabe\" }"
        return
    fi
    if [ "$CMD_METHOD" != "GET" ]; then
        http_405; json_err "{ \"error\": \"Methode $CMD_METHOD nicht erlaubt. /getAufgabe erwartet GET.\" }"
        return
    fi
    if [ -z "$CMD_AUTH_HEADER" ]; then
        http_401; json_err "{ \"error\": \"Header 'Authorization' fehlt.\" }"
        hint 'Header setzt man mit  -H "Authorization: Bearer DEIN-TOKEN"'
        return
    fi
    if [ "$CMD_AUTH_HEADER" != "Bearer $TOKEN" ]; then
        http_401; json_err "{ \"error\": \"Token ungültig oder falsches Format. Erwartet: Bearer <token>.\" }"
        return
    fi

    # Zufällige Aufgabe wählen
    local idx=$(( RANDOM % ${#QUESTIONS[@]} ))
    local entry="${QUESTIONS[$idx]}"
    QUESTION_TEXT="${entry%%|*}"
    QUESTION_ANSWER="${entry#*|}"
    AUFGABEN_ID="q-$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || echo "ab12")"

    http_ok
    echo -e "  ${DIM}< Content-Type: application/json${NC}"
    json_ok "{"
    json_ok "  \"aufgabenId\": \"$AUFGABEN_ID\","
    json_ok "  \"frage\": \"$QUESTION_TEXT\""
    json_ok "}"
    echo ""
    echo -e "  ${GREEN}✓ Aufgabe geladen. Deine Frage lautet:${NC}"
    echo -e "  ${YELLOW}  \"$QUESTION_TEXT\"${NC}"
    STEP=3
}

# ─── Server-Simulation: /postAntwort ─────────────────────────────────────────
server_post_antwort() {
    if [[ "$CMD_URL" != *"api.hochschule-lab.de"* ]]; then
        echo -e "  ${RED}curl: (6) Could not resolve host: $(echo "$CMD_URL" | sed 's|https\?://||' | cut -d/ -f1)${NC}"
        return
    fi
    if [[ "$CMD_PATH" != *"/postAntwort"* ]]; then
        http_404; json_err "{ \"error\": \"Endpoint '${CMD_PATH##*/}' existiert nicht. Erwartet: /postAntwort\" }"
        return
    fi
    if [ "$CMD_METHOD" != "POST" ]; then
        http_405; json_err "{ \"error\": \"Methode $CMD_METHOD nicht erlaubt. /postAntwort erwartet POST.\" }"
        hint 'Mit -X POST oder implizit durch -d setzt curl die Methode auf POST.'
        return
    fi
    if [ -z "$CMD_AUTH_HEADER" ]; then
        http_401; json_err "{ \"error\": \"Header 'Authorization' fehlt.\" }"
        return
    fi
    if [ "$CMD_AUTH_HEADER" != "Bearer $TOKEN" ]; then
        http_401; json_err "{ \"error\": \"Token ungültig.\" }"
        return
    fi
    if [[ "${CMD_CT_HEADER,,}" != *"application/json"* ]]; then
        http_415; json_err "{ \"error\": \"Header 'Content-Type: application/json' fehlt.\" }"
        hint 'Body ist JSON, also -H "Content-Type: application/json"'
        return
    fi
    if [ -z "$CMD_BODY" ]; then
        http_400; json_err "{ \"error\": \"Request-Body fehlt.\" }"
        hint "JSON-Body mitgeben mit  -d '{\"antwort\":\"...\"}'"
        return
    fi

    # "antwort"-Feld aus JSON extrahieren (einfach mit grep/sed)
    local user_answer
    user_answer=$(echo "$CMD_BODY" | grep -o '"antwort"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"antwort"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    if [ -z "$user_answer" ]; then
        http_400; json_err "{ \"error\": \"Feld 'antwort' fehlt im JSON-Body.\" }"
        return
    fi

    # Antwort vergleichen (case-insensitive)
    local correct=0
    IFS='|' read -ra accepted <<< "$QUESTION_ANSWER"
    for acc in "${accepted[@]}"; do
        if [ "${user_answer,,}" = "${acc,,}" ]; then
            correct=1; break
        fi
    done

    if [ $correct -eq 1 ]; then
        http_ok
        echo -e "  ${DIM}< Content-Type: application/json${NC}"
        json_ok "{"
        json_ok "  \"richtig\": true,"
        json_ok "  \"message\": \"Antwort korrekt — super gemacht!\""
        json_ok "}"
        echo ""
        echo -e "  ${GREEN}🎉  Alle drei Schritte geschafft. Tolle Arbeit!${NC}"
        echo ""
        echo -e "  ${DIM}Tippe 'reset' um neu zu starten, 'exit' zum Beenden.${NC}"
        STEP=4
    else
        http_ok
        echo -e "  ${DIM}< Content-Type: application/json${NC}"
        json_warn "{"
        json_warn "  \"richtig\": false,"
        json_warn "  \"message\": \"Antwort leider nicht korrekt. Versuch es nochmal.\""
        json_warn "}"
        echo ""
        echo -e "  ${YELLOW}✗ Falsche Antwort. Sende den POST erneut mit korrektem Wert.${NC}"
    fi
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
dispatch() {
    local cmd="$1"

    # Meta-Kommandos
    case "$cmd" in
        clear|cls)
            clear; show_header; return ;;
        reset)
            STEP=1; TOKEN=""; QUESTION_TEXT=""; QUESTION_ANSWER=""; AUFGABEN_ID=""
            echo -e "  ${CYAN}→ Zurückgesetzt auf Schritt 1.${NC}"; return ;;
        exit|quit)
            echo -e "${GREEN}Tschüss!${NC}"; exit 0 ;;
        help|hilfe|\?)
            show_help; return ;;
        "")
            return ;;
    esac

    # curl parsen
    if ! parse_curl "$cmd"; then
        echo -e "  ${RED}Fehler: $PARSE_ERROR${NC}"
        return
    fi

    echo ""

    # Routing nach Schritt
    case "$STEP" in
        1) server_get_token ;;
        2)
            if [[ "$CMD_PATH" == *"/getToken"* ]]; then
                server_get_token
            else
                server_get_aufgabe
            fi
            ;;
        3)
            if [[ "$CMD_PATH" == *"/getToken"* ]]; then
                server_get_token
            elif [[ "$CMD_PATH" == *"/getAufgabe"* ]]; then
                server_get_aufgabe
            else
                server_post_antwort
            fi
            ;;
        4)
            echo -e "  ${DIM}Übung abgeschlossen. Tippe 'reset' für einen neuen Durchgang.${NC}" ;;
    esac
}

# ─── Willkommen + Hilfe ───────────────────────────────────────────────────────
show_header() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   API-LABOR  —  DHGE Webentwicklung                         ║${NC}"
    echo -e "${BOLD}║   Übung: REST-API mit curl bedienen                         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    separator
    show_steps
    separator
}

show_welcome() {
    show_header
    echo ""
    echo -e "  ${DIM}Ziel: Drei curl-Befehle, die korrekt den Server ansprechen.${NC}"
    echo -e "  ${DIM}Tippe 'help' für Hilfebefehle mit Beispielen.${NC}"
    echo ""
    echo -e "  ${CYAN}Deine Zugangsdaten:${NC}"
    echo -e "    Login:     ${YELLOW}$LOGIN${NC}"
    echo -e "    Kursname:  ${YELLOW}$KURS${NC}"
    echo -e "    API-URL:   ${YELLOW}$BASE_URL${NC}"
    echo ""
    separator
    echo -e "  ${BOLD}SCHRITT 1/3 — Token anfordern${NC}"
    echo -e "  ${DIM}Sende einen GET-Request an /getToken mit deinen${NC}"
    echo -e "  ${DIM}Daten als URL-Parameter (login, kurs).${NC}"
    echo ""
}

show_help() {
    echo ""
    echo -e "${BOLD}─── Hilfe ───────────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${CYAN}SCHRITT 1 — Token holen${NC}  (GET /getToken)"
    echo -e "  ${DIM}curl \"$BASE_URL/getToken?login=$LOGIN&kurs=$KURS\"${NC}"
    echo ""
    echo -e "  ${CYAN}SCHRITT 2 — Aufgabe laden${NC}  (GET /getAufgabe)"
    echo -e "  ${DIM}curl -H \"Authorization: Bearer DEIN-TOKEN\" \\${NC}"
    echo -e "  ${DIM}     \"$BASE_URL/getAufgabe\"${NC}"
    echo ""
    echo -e "  ${CYAN}SCHRITT 3 — Antwort senden${NC}  (POST /postAntwort)"
    echo -e "  ${DIM}curl -X POST \\${NC}"
    echo -e "  ${DIM}     -H \"Authorization: Bearer DEIN-TOKEN\" \\${NC}"
    echo -e "  ${DIM}     -H \"Content-Type: application/json\" \\${NC}"
    echo -e "  ${DIM}     -d '{\"antwort\":\"DEINE-ANTWORT\"}' \\${NC}"
    echo -e "  ${DIM}     \"$BASE_URL/postAntwort\"${NC}"
    echo ""
    echo -e "  ${BOLD}Meta-Befehle:${NC}"
    echo -e "    ${YELLOW}reset${NC}   — Übung neu starten"
    echo -e "    ${YELLOW}clear${NC}   — Bildschirm leeren"
    echo -e "    ${YELLOW}help${NC}    — Diese Hilfe"
    echo -e "    ${YELLOW}exit${NC}    — Beenden"
    echo ""
    separator
}

# ─── Hauptschleife ────────────────────────────────────────────────────────────
show_welcome

while true; do
    # Schritt-Hinweis vor jedem Prompt
    if [ "$STEP" -eq 2 ] && [ -n "$TOKEN" ]; then
        echo -e "  ${BOLD}SCHRITT 2/3 — Aufgabe laden${NC}"
        echo -e "  ${DIM}Sende GET an /getAufgabe mit deinem Token im Authorization-Header.${NC}"
        echo -e "  ${DIM}TOKEN: $TOKEN${NC}"
        echo ""
    elif [ "$STEP" -eq 3 ] && [ -n "$QUESTION_TEXT" ]; then
        echo -e "  ${BOLD}SCHRITT 3/3 — Antwort senden${NC}"
        echo -e "  ${YELLOW}  Frage: \"$QUESTION_TEXT\"${NC}"
        echo -e "  ${DIM}Sende POST an /postAntwort mit Token + JSON-Body {\"antwort\":\"...\"}${NC}"
        echo ""
    fi

    # Eingabe
    print_prompt
    read -r INPUT || { echo ""; break; }

    print_echo "$INPUT"
    dispatch "$INPUT"

    echo ""

    # Nach Abschluss Schritt-Anzeige aktualisieren
    separator
    show_steps
    separator
    echo ""
done
