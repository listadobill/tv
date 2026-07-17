#!/bin/bash

# =====================================================================
# EXTRATOR UNIVERSAL IPTV 3.0 (FULL CONTENT EDITION)
# =====================================================================

# Cores para saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Dependências
check_dependencies() {
    for cmd in curl jq sed awk grep; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}[ERRO] Comando '$cmd' não encontrado. Por favor, instale-o.${NC}"
            exit 1
        fi
    done
}

# Configurações de Emulação (MAG250)
USER_AGENT="Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"
X_USER_AGENT="Model: MAG250; Link: WiFi"

# --- Módulo Stalker ---
extract_stalker() {
    local PORTAL_URL=$1
    local MAC_ADDRESS=$2
    local OUTPUT_FILE="stalker_full_list.m3u"
    
    echo -e "${BLUE}[STALKER] Iniciando extração completa para MAC: $MAC_ADDRESS${NC}"
    
    PORTAL_URL=$(echo "$PORTAL_URL" | sed 's/\/*$//')
    PORTAL_HOST=$(echo "$PORTAL_URL" | sed -e 's/^https\?:\/\///' -e 's/\/.*$//')
    
    local API_PATHS=("/server/load.php" "/portal.php" "/loader.php")
    local VALID_PATH=""
    
    for path in "${API_PATHS[@]}"; do
        echo -e "${YELLOW}[INFO] Testando caminho: $path${NC}"
        local TEST_URL="${PORTAL_URL}${path}?type=stb&action=handshake&JsHttpRequest=1-xml"
        local CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: $USER_AGENT" "$TEST_URL")
        if [ "$CODE" == "200" ]; then
            VALID_PATH=$path
            break
        fi
    done
    
    if [ -z "$VALID_PATH" ]; then
        echo -e "${RED}[ERRO] Portal não encontrado (404).${NC}"
        return 1
    fi

    local RANDOM_VAL=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
    local HANDSHAKE_URL="${PORTAL_URL}${VALID_PATH}?type=stb&action=handshake&JsHttpRequest=1-xml"
    local RESPONSE=$(curl -s --compressed -H "User-Agent: $USER_AGENT" -H "Host: $PORTAL_HOST" --cookie "mac=$MAC_ADDRESS; random=$RANDOM_VAL" "$HANDSHAKE_URL")
    local TOKEN=$(echo "$RESPONSE" | jq -r ".js.token" 2>/dev/null)

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        echo -e "${RED}[ERRO] Falha no Handshake.${NC}"
        return 1
    fi

    echo -e "${GREEN}[INFO] Token obtido. Extraindo todas as categorias...${NC}"
    
    echo "#EXTM3U" > "$OUTPUT_FILE"
    
    # Obter gêneros de TV e VOD
    local GENRE_TYPES=("itv" "vod" "series")
    for type in "${GENRE_TYPES[@]}"; do
        echo -e "${BLUE}[INFO] Buscando categorias do tipo: $type${NC}"
        local GENRES_URL="${PORTAL_URL}${VALID_PATH}?type=$type&action=get_genres&JsHttpRequest=1-xml"
        local GENRES_RESP=$(curl -s --compressed -H "User-Agent: $USER_AGENT" --cookie "mac=$MAC_ADDRESS; token=$TOKEN" "$GENRES_URL")
        local GENRES=$(echo "$GENRES_RESP" | jq -c ".js[]" 2>/dev/null)

        while IFS= read -r genre; do
            [ -z "$genre" ] && continue
            local G_ID=$(echo "$genre" | jq -r ".id")
            local G_NAME=$(echo "$genre" | jq -r ".title")
            
            echo -e "${YELLOW}[INFO] Processando: [$type] $G_NAME${NC}"
            
            # Lógica de Paginação
            local PAGE=0
            while true; do
                local CH_URL="${PORTAL_URL}${VALID_PATH}?type=$type&action=get_ordered_list&genre=$G_ID&p=$PAGE&JsHttpRequest=1-xml"
                local CH_RESP=$(curl -s --compressed -H "User-Agent: $USER_AGENT" --cookie "mac=$MAC_ADDRESS; token=$TOKEN" "$CH_URL")
                
                # Verificar se há dados
                local DATA=$(echo "$CH_RESP" | jq -c ".js.data[]" 2>/dev/null)
                if [[ -z "$DATA" ]]; then break; fi
                
                echo "$DATA" | while read -r item; do
                    local NAME=$(echo "$item" | jq -r ".name // .title")
                    local CMD=$(echo "$item" | jq -r ".cmd")
                    
                    if [[ "$type" == "itv" ]]; then
                        local LINK_URL="${PORTAL_URL}${VALID_PATH}?type=itv&action=create_link&cmd=$(echo "$CMD" | jq -sRr @uri)&JsHttpRequest=1-xml"
                        local L_RESP=$(curl -s --compressed -H "User-Agent: $USER_AGENT" --cookie "mac=$MAC_ADDRESS; token=$TOKEN" "$LINK_URL")
                        local FINAL_URL=$(echo "$L_RESP" | jq -r ".js.url // .js.cmd" | sed 's/^ffmpeg //i')
                    else
                        # Para VOD/Series, o link geralmente já está no cmd ou precisa de create_link similar
                        local FINAL_URL=$(echo "$CMD" | sed 's/^ffmpeg //i')
                    fi
                    
                    if [[ "$FINAL_URL" != "null" && -n "$FINAL_URL" ]]; then
                        echo "#EXTINF:-1 group-title=\"$G_NAME\",$NAME" >> "$OUTPUT_FILE"
                        echo "$FINAL_URL" >> "$OUTPUT_FILE"
                    fi
                done
                
                # Verificar se há próxima página (Stalker costuma ter 'total_items')
                local TOTAL=$(echo "$CH_RESP" | jq -r ".js.total_items // 0")
                local CURRENT_COUNT=$(( (PAGE + 1) * 30 )) # Stalker padrão é 30 por página
                if (( CURRENT_COUNT >= TOTAL )) && [[ "$TOTAL" != "0" ]]; then break; fi
                
                ((PAGE++))
                # Limite de segurança para evitar loops infinitos
                if (( PAGE > 100 )); then break; fi
            done
        done <<< "$GENRES"
    done
    
    echo -e "${GREEN}[SUCESSO] Extração completa salva em: $OUTPUT_FILE${NC}"
}

# --- Módulo Xtream ---
extract_xtream() {
    local URL=$1
    local USER=$2
    local PASS=$3
    local OUTPUT_FILE="xtream_full_list.m3u"
    
    echo -e "${BLUE}[XTREAM] Iniciando extração total (Live, VOD, Series)...${NC}"
    
    local LOGIN_URL="${URL}/player_api.php?username=${USER}&password=${PASS}"
    local AUTH=$(curl -s "$LOGIN_URL")
    
    if [[ $(echo "$AUTH" | jq -r ".user_info.auth") != "1" ]]; then
        echo -e "${RED}[ERRO] Falha na autenticação Xtream.${NC}"
        return 1
    fi
    
    echo "#EXTM3U" > "$OUTPUT_FILE"
    
    local ACTIONS=("get_live_streams" "get_vod_streams" "get_series")
    for action in "${ACTIONS[@]}"; do
        echo -e "${YELLOW}[INFO] Extraindo: $action${NC}"
        local DATA=$(curl -s "${URL}/player_api.php?username=${USER}&password=${PASS}&action=$action")
        
        echo "$DATA" | jq -c ".[]" 2>/dev/null | while read -r item; do
            local NAME=$(echo "$item" | jq -r ".name")
            local ID=$(echo "$item" | jq -r ".stream_id // .series_id")
            local CAT=$(echo "$item" | jq -r ".category_id")
            
            if [[ "$action" == "get_live_streams" ]]; then
                local EXT=$(echo "$item" | jq -r ".container_extension // \"ts\"")
                echo "#EXTINF:-1 group-title=\"LIVE_$CAT\",$NAME" >> "$OUTPUT_FILE"
                echo "${URL}/live/${USER}/${PASS}/${ID}.${EXT}" >> "$OUTPUT_FILE"
            elif [[ "$action" == "get_vod_streams" ]]; then
                local EXT=$(echo "$item" | jq -r ".container_extension // \"mp4\"")
                echo "#EXTINF:-1 group-title=\"VOD_$CAT\",$NAME" >> "$OUTPUT_FILE"
                echo "${URL}/movie/${USER}/${PASS}/${ID}.${EXT}" >> "$OUTPUT_FILE"
            else
                echo "#EXTINF:-1 group-title=\"SERIES_$CAT\",$NAME" >> "$OUTPUT_FILE"
                echo "${URL}/series/${USER}/${PASS}/${ID}.mp4" >> "$OUTPUT_FILE"
            fi
        done
    done
    
    echo -e "${GREEN}[SUCESSO] Lista completa salva em: $OUTPUT_FILE${NC}"
}

# --- Módulo M3U ---
extract_m3u() {
    local URL=$1
    local OUTPUT_FILE="full_m3u_list.m3u"
    echo -e "${BLUE}[M3U] Baixando lista...${NC}"
    curl -s -L -o "$OUTPUT_FILE" "$USER_AGENT" "$URL"
    echo -e "${GREEN}[SUCESSO] Lista salva em: $OUTPUT_FILE${NC}"
}

# --- Detecção e Interface ---
detect_and_extract() {
    local INPUT=$1
    if [[ "$INPUT" == *"mac="* ]] || [[ "$INPUT" == *"00:1A:79"* ]]; then
        local URL=$(echo "$INPUT" | grep -oP "http[s]?://[^ ]+")
        local MAC=$(echo "$INPUT" | grep -oP "([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})")
        extract_stalker "$URL" "$MAC"
    elif [[ "$INPUT" == *"username="* ]] && [[ "$INPUT" == *"password="* ]]; then
        local URL=$(echo "$INPUT" | grep -oP "http[s]?://[^/]+")
        local USER=$(echo "$INPUT" | grep -oP "(?<=username=)[^&]+")
        local PASS=$(echo "$INPUT" | grep -oP "(?<=password=)[^&]+")
        extract_xtream "$URL" "$USER" "$PASS"
    elif [[ "$INPUT" == *".m3u"* ]]; then
        extract_m3u "$INPUT"
    else
        echo -e "${RED}[ERRO] Não foi possível identificar o formato automaticamente.${NC}"
    fi
}

main() {
    check_dependencies
    clear
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}       EXTRATOR UNIVERSAL IPTV 3.0        ${NC}"
    echo -e "${BLUE}        (EXTRAÇÃO TOTAL ATIVADA)          ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
    echo "0) Detecção Automática (Recomendado)"
    echo "1) Stalker Portal (Manual)"
    echo "2) Xtream Codes (Manual)"
    echo "3) M3U Direto (Manual)"
    echo ""
    read -p "Opção: " OPT
    case $OPT in
        0) read -p "Cole o link completo: " RAW; detect_and_extract "$RAW" ;;
        1) read -p "URL: " U; read -p "MAC: " M; extract_stalker "$U" "$M" ;;
        2) read -p "URL: " U; read -p "User: " US; read -p "Pass: " PS; extract_xtream "$U" "$US" "$PS" ;;
        3) read -p "URL: " U; extract_m3u "$U" ;;
    esac
}

main
