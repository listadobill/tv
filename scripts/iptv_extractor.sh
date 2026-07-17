#!/bin/bash

# =====================================================================
# EXTRATOR UNIVERSAL IPTV (Stalker, Xtream, M3U)
# Versão: 2.0
# =====================================================================

# Cores para saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Dependências
check_dependencies() {
    for cmd in curl jq sed awk; do
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
    local OUTPUT_FILE="stalker_channels.m3u"
    
    echo -e "${BLUE}[STALKER] Iniciando extração para MAC: $MAC_ADDRESS${NC}"
    
    # Normalizar URL
    PORTAL_URL=$(echo "$PORTAL_URL" | sed 's/\/*$//')
    PORTAL_HOST=$(echo "$PORTAL_URL" | sed -e 's/^https\?:\/\///' -e 's/\/.*$//')
    
    # Tentar caminhos comuns de API
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
        echo -e "${RED}[ERRO] Não foi possível encontrar o endpoint da API Stalker (404 em todos os caminhos testados).${NC}"
        return 1
    fi

    # Handshake
    local RANDOM_VAL=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40)
    local HANDSHAKE_URL="${PORTAL_URL}${VALID_PATH}?type=stb&action=handshake&JsHttpRequest=1-xml"
    local RESPONSE=$(curl -s --compressed -H "User-Agent: $USER_AGENT" -H "Host: $PORTAL_HOST" --cookie "mac=$MAC_ADDRESS; random=$RANDOM_VAL" "$HANDSHAKE_URL")
    local TOKEN=$(echo "$RESPONSE" | jq -r ".js.token" 2>/dev/null)

    if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
        echo -e "${RED}[ERRO] Falha no Handshake. Resposta: $RESPONSE${NC}"
        return 1
    fi

    echo -e "${GREEN}[INFO] Token obtido: $TOKEN${NC}"
    
    # Obter Categorias
    local GENRES_URL="${PORTAL_URL}${VALID_PATH}?type=itv&action=get_genres&JsHttpRequest=1-xml"
    local GENRES_RESP=$(curl -s --compressed -H "User-Agent: $USER_AGENT" --cookie "mac=$MAC_ADDRESS; token=$TOKEN" "$GENRES_URL")
    local GENRES=$(echo "$GENRES_RESP" | jq -c ".js[]" 2>/dev/null)

    echo "#EXTM3U" > "$OUTPUT_FILE"
    
    while IFS= read -r genre; do
        [ -z "$genre" ] && continue
        local G_ID=$(echo "$genre" | jq -r ".id")
        local G_NAME=$(echo "$genre" | jq -r ".title")
        echo -e "${YELLOW}[INFO] Categoria: $G_NAME${NC}"
        
        local CH_URL="${PORTAL_URL}${VALID_PATH}?type=itv&action=get_ordered_list&genre=$G_ID&JsHttpRequest=1-xml"
        local CH_RESP=$(curl -s --compressed -H "User-Agent: $USER_AGENT" --cookie "mac=$MAC_ADDRESS; token=$TOKEN" "$CH_URL")
        
        echo "$CH_RESP" | jq -c ".js.data[]" 2>/dev/null | while read -r channel; do
            local NAME=$(echo "$channel" | jq -r ".name")
            local CMD=$(echo "$channel" | jq -r ".cmd")
            
            # Criar Link
            local LINK_URL="${PORTAL_URL}${VALID_PATH}?type=itv&action=create_link&cmd=$(echo "$CMD" | jq -sRr @uri)&JsHttpRequest=1-xml"
            local L_RESP=$(curl -s --compressed -H "User-Agent: $USER_AGENT" --cookie "mac=$MAC_ADDRESS; token=$TOKEN" "$LINK_URL")
            local FINAL_URL=$(echo "$L_RESP" | jq -r ".js.url // .js.cmd" | sed 's/^ffmpeg //i')
            
            if [[ "$FINAL_URL" != "null" && -n "$FINAL_URL" ]]; then
                echo "#EXTINF:-1 group-title=\"$G_NAME\",$NAME" >> "$OUTPUT_FILE"
                echo "$FINAL_URL" >> "$OUTPUT_FILE"
            fi
        done
    done <<< "$GENRES"
    
    echo -e "${GREEN}[SUCESSO] Lista salva em: $OUTPUT_FILE${NC}"
}

# --- Módulo Xtream ---
extract_xtream() {
    local URL=$1
    local USER=$2
    local PASS=$3
    local OUTPUT_FILE="xtream_channels.m3u"
    
    echo -e "${BLUE}[XTREAM] Iniciando extração para usuário: $USER${NC}"
    
    # Login e Info
    local LOGIN_URL="${URL}/player_api.php?username=${USER}&password=${PASS}"
    local AUTH=$(curl -s "$LOGIN_URL")
    
    if [[ $(echo "$AUTH" | jq -r ".user_info.auth") != "1" ]]; then
        echo -e "${RED}[ERRO] Falha na autenticação Xtream.${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[INFO] Autenticado com sucesso!${NC}"
    
    # Obter Canais
    echo "#EXTM3U" > "$OUTPUT_FILE"
    local CHANNELS=$(curl -s "${URL}/player_api.php?username=${USER}&password=${PASS}&action=get_live_streams")
    
    echo "$CHANNELS" | jq -c ".[]" 2>/dev/null | while read -r ch; do
        local NAME=$(echo "$ch" | jq -r ".name")
        local ID=$(echo "$ch" | jq -r ".stream_id")
        local EXT=$(echo "$ch" | jq -r ".container_extension // \"ts\"")
        local CAT=$(echo "$ch" | jq -r ".category_id")
        
        local STREAM_URL="${URL}/live/${USER}/${PASS}/${ID}.${EXT}"
        echo "#EXTINF:-1 tvg-id=\"$ID\" group-title=\"$CAT\",$NAME" >> "$OUTPUT_FILE"
        echo "$STREAM_URL" >> "$OUTPUT_FILE"
    done
    
    echo -e "${GREEN}[SUCESSO] Lista salva em: $OUTPUT_FILE${NC}"
}

# --- Módulo M3U ---
extract_m3u() {
    local URL=$1
    local OUTPUT_FILE="downloaded_list.m3u"
    
    echo -e "${BLUE}[M3U] Baixando lista direta...${NC}"
    curl -s -L -o "$OUTPUT_FILE" "$URL"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[SUCESSO] Lista salva em: $OUTPUT_FILE${NC}"
    else
        echo -e "${RED}[ERRO] Falha ao baixar a lista M3U.${NC}"
    fi
}

# --- Detecção Automática ---
detect_and_extract() {
    local INPUT=$1
    
    # Se contém /c/ ou /portal.php e termina com MAC ou pede MAC
    if [[ "$INPUT" == *"mac="* ]] || [[ "$INPUT" == *"00:1A:79"* ]]; then
        local URL=$(echo "$INPUT" | grep -oP "http[s]?://[^ ]+")
        local MAC=$(echo "$INPUT" | grep -oP "([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})")
        extract_stalker "$URL" "$MAC"
    # Se contém player_api.php ou username/password
    elif [[ "$INPUT" == *"username="* ]] && [[ "$INPUT" == *"password="* ]]; then
        local URL=$(echo "$INPUT" | grep -oP "http[s]?://[^/]+")
        local USER=$(echo "$INPUT" | grep -oP "(?<=username=)[^&]+")
        local PASS=$(echo "$INPUT" | grep -oP "(?<=password=)[^&]+")
        extract_xtream "$URL" "$USER" "$PASS"
    # Se é um link M3U direto
    elif [[ "$INPUT" == *".m3u"* ]]; then
        extract_m3u "$INPUT"
    else
        echo -e "${YELLOW}[AVISO] Não foi possível detectar o tipo automaticamente. Use o menu manual.${NC}"
        return 1
    fi
}

# --- Interface Principal ---
main() {
    check_dependencies
    clear
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}       EXTRATOR UNIVERSAL IPTV 2.0        ${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
    echo "Cole o link/credenciais ou escolha uma opção:"
    echo "0) Detecção Automática (Cole o link completo aqui)"
    echo "1) Stalker Portal (Manual: URL + MAC)"
    echo "2) Xtream Codes (Manual: URL + User + Pass)"
    echo "3) M3U Direto (Manual: URL)"
    echo ""
    read -p "Opção: " OPT
    
    case $OPT in
        0)
            read -p "Cole o link/texto: " RAW_INPUT
            detect_and_extract "$RAW_INPUT"
            ;;
        1)
            read -p "URL do Portal: " P_URL
            read -p "Endereço MAC: " P_MAC
            extract_stalker "$P_URL" "$P_MAC"
            ;;
        2)
            read -p "URL do Servidor: " X_URL
            read -p "Usuário: " X_USER
            read -p "Senha: " X_PASS
            extract_xtream "$X_URL" "$X_USER" "$X_PASS"
            ;;
        3)
            read -p "URL M3U: " M_URL
            extract_m3u "$M_URL"
            ;;
        *)
            echo -e "${RED}Opção inválida.${NC}"
            ;;
    esac
}

main
