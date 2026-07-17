#!/bin/bash

# --- PASSO ZERO: Verificação inteligente de dependências ---
echo "[INFO] Verificando dependências..."

MESSING_PACKAGES=()

# Testa se o curl está disponível no sistema
if ! command -v curl &> /dev/null; then
    MESSING_PACKAGES+=("curl")
fi

# Testa se o jq está disponível no sistema
if ! command -v jq &> /dev/null; then
    MESSING_PACKAGES+=("jq")
fi

# Se houver pacotes faltando, instala-os. Se não, ignora silenciosamente.
if [ ${#MESSING_PACKAGES[@]} -ne 0 ]; then
    echo "[INFO] Instalando pacotes ausentes: ${MESSING_PACKAGES[*]}..."
    sudo dnf install "${MESSING_PACKAGES[@]}" -y
else
    echo "[INFO] Todas as dependências (curl, jq) já estão instaladas. Pulando etapa de instalação."
fi

# =====================================================================
# CONFIGURAÇÕES (Edite apenas estes dois valores para mudar de portal)
# =====================================================================
PORTAL_URL="http://pro.most8knew.com/c"
MAC_ADDRESS="00:1A:79:7A:4C:A1"
# =====================================================================

# Limpeza automática da URL (Remove barras sobressalentes no final)
PORTAL_URL=$(echo "$PORTAL_URL" | sed 's/\/*$//')

# Pasta de saída onde todas as categorias e o arquivo do Brasil serão salvos
OUTPUT_DIR="canais_extraidos"
mkdir -p "$OUTPUT_DIR"

# User-Agents modernos para emulação fiel de MAG 250/254 (Evita bloqueios)
USER_AGENT="Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"
X_USER_AGENT="Model: MAG250; Link: WiFi"

# Funções geradoras de credenciais baseadas no MAC
generate_random_value() {
    head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40
}

generate_device_id() {
    echo -n "$MAC_ADDRESS" | sha256sum | awk '{print toupper(substr($1, 1, 64))}'
}

generate_serial() {
    echo -n "$MAC_ADDRESS" | md5sum | awk '{print toupper(substr($1, 1, 13))}'
}

RANDOM_VALUE=$(generate_random_value)
DEVICE_ID=$(generate_device_id)
SERIAL=$(generate_serial)

# Extrai o host puro (ex: pro.most8knew.com) para injetar no cabeçalho HTTP
PORTAL_HOST=$(echo "$PORTAL_URL" | sed -e 's/^https\?:\/\///' -e 's/\/.*$//')

# --- PASSO 1: HANDSHAKE (Obtenção do token de sessão) ---
echo "[INFO] Realizando handshake com o portal..."

HANDSHAKE_URL="${PORTAL_URL}/server/load.php?type=stb&action=handshake&JsHttpRequest=1-xml"

# Adicionada a flag --compressed para evitar caracteres corrompidos
HANDSHAKE_RESPONSE=$(curl -s --compressed -X GET \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-User-Agent: ${X_USER_AGENT}" \
    -H "Referer: ${PORTAL_URL}/index.html" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Pragma: no-cache" \
    -H "Host: ${PORTAL_HOST}" \
    -H "Connection: Keep-Alive" \
    --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; random=${RANDOM_VALUE}" \
    "${HANDSHAKE_URL}")

TOKEN=$(echo "$HANDSHAKE_RESPONSE" | jq -r ".js.token")

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "[ERRO] Falha ao obter o token de handshake."
    echo "Resposta recebida do servidor: $HANDSHAKE_RESPONSE"
    exit 1
fi

echo "[INFO] Token obtido com sucesso: $TOKEN"

# --- PASSO 2: GET PROFILE (Autenticação do dispositivo no portal) ---
echo "[INFO] Enviando perfil do dispositivo..."

PROFILE_URL="${PORTAL_URL}/server/load.php?type=stb&action=get_profile&JsHttpRequest=1-xml"
SIGNATURE=$(echo -n "${MAC_ADDRESS}${SERIAL}${DEVICE_ID}${DEVICE_ID}" | sha256sum | awk '{print toupper($1)}')

PROFILE_RESPONSE=$(curl -s --compressed -X GET \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-User-Agent: ${X_USER_AGENT}" \
    -H "Referer: ${PORTAL_URL}/index.html" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Pragma: no-cache" \
    -H "Host: ${PORTAL_HOST}" \
    -H "Connection: Keep-Alive" \
    --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
    --data-urlencode "sn=${SERIAL}" \
    --data-urlencode "device_id=${DEVICE_ID}" \
    --data-urlencode "device_id2=${DEVICE_ID}" \
    --data-urlencode "signature=${SIGNATURE}" \
    --data-urlencode "metrics={\"mac\":\"${MAC_ADDRESS}\",\"sn\":\"${SERIAL}\",\"type\":\"STB\",\"model\":\"MAG250\",\"uid\":\"\",\"random\":\"${RANDOM_VALUE}\"}" \
    "${PROFILE_URL}")

if ! echo "$PROFILE_RESPONSE" | jq -e "." > /dev/null 2>&1; then
    echo "[AVISO] Perfil não retornou JSON válido, mas o script continuará tentando obter os canais."
fi

# --- PASSO 3: OBTER CATEGORIAS DE CANAIS ---
echo "[INFO] Obtendo categorias de canais..."

CATEGORIES_URL="${PORTAL_URL}/server/load.php?type=itv&action=get_genres&JsHttpRequest=1-xml"

CATEGORIES_RESPONSE=$(curl -s --compressed -X GET \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-User-Agent: ${X_USER_AGENT}" \
    -H "Referer: ${PORTAL_URL}/index.html" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Pragma: no-cache" \
    -H "Host: ${PORTAL_HOST}" \
    -H "Connection: Keep-Alive" \
    --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
    "${CATEGORIES_URL}")

CATEGORIES=$(echo "$CATEGORIES_RESPONSE" | jq -c ".js[]" 2>/dev/null)

if [ -z "$CATEGORIES" ]; then
    echo "[ERRO] Não foi possível ler as categorias do portal. Resposta do servidor: $CATEGORIES_RESPONSE"
    exit 1
fi

# --- PASSO 4: OBTER CANAIS POR CATEGORIA E SEPARAR ---
echo "[INFO] Processando canais..."

# Criando a lista unificada para canais brasileiros
BRAZIL_FILE="${OUTPUT_DIR}/Brasil.m3u"
echo "#EXTM3U" > "$BRAZIL_FILE"

while IFS= read -r category;
do
    CATEGORY_ID=$(echo "$category" | jq -r ".id")
    CATEGORY_NAME=$(echo "$category" | jq -r ".title")

    # Limpa caracteres especiais do nome das pastas/arquivos de categoria
    SAFE_CATEGORY_NAME=$(echo "$CATEGORY_NAME" | sed 's/[^A-Za-z0-9_-]/_/g')
    CATEGORY_FILE="${OUTPUT_DIR}/${SAFE_CATEGORY_NAME}.m3u"
    
    echo "#EXTM3U" > "$CATEGORY_FILE"

    echo "[INFO] Baixando categoria: $CATEGORY_NAME"

    CHANNELS_URL="${PORTAL_URL}/server/load.php?type=itv&action=get_ordered_list&genre=${CATEGORY_ID}&JsHttpRequest=1-xml"

    CHANNELS_RESPONSE=$(curl -s --compressed -X GET \
        -H "User-Agent: ${USER_AGENT}" \
        -H "X-User-Agent: ${X_USER_AGENT}" \
        -H "Referer: ${PORTAL_URL}/index.html" \
        -H "Accept-Language: en-US,en;q=0.5" \
        -H "Pragma: no-cache" \
        -H "Host: ${PORTAL_HOST}" \
        -H "Connection: Keep-Alive" \
        --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
        "${CHANNELS_URL}")

    CHANNELS=$(echo "$CHANNELS_RESPONSE" | jq -c ".js.data[]" 2>/dev/null)

    if [ -z "$CHANNELS" ]; then
        rm -f "$CATEGORY_FILE"
        continue
    fi

    while IFS= read -r channel;
    do
        CHANNEL_NAME=$(echo "$channel" | jq -r ".name")
        CHANNEL_CMD=$(echo "$channel" | jq -r ".cmd")
        CHANNEL_ID=$(echo "$channel" | jq -r ".id")

        if [ -z "$CHANNEL_CMD" ] || [ "$CHANNEL_CMD" == "null" ]; then
            continue
        fi

        # --- PASSO 5: REQUISITAR O LINK DE TRANSMISSÃO ---
        CREATE_LINK_URL="${PORTAL_URL}/server/load.php?type=itv&action=create_link&cmd=$(echo "$CHANNEL_CMD" | jq -sRr @uri)&JsHttpRequest=1-xml"

        STREAM_RESPONSE=$(curl -s --compressed -X GET \
            -H "User-Agent: ${USER_AGENT}" \
            -H "X-User-Agent: ${X_USER_AGENT}" \
            -H "Referer: ${PORTAL_URL}/index.html" \
            -H "Accept-Language: en-US,en;q=0.5" \
            -H "Pragma: no-cache" \
            -H "Host: ${PORTAL_HOST}" \
            -H "Connection: Keep-Alive" \
            --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
            "${CREATE_LINK_URL}")

        STREAM_URL=$(echo "$STREAM_RESPONSE" | jq -r ".js.url // .js.cmd")

        if [ -z "$STREAM_URL" ] || [ "$STREAM_URL" == "null" ]; then
            continue
        fi

        # Remove formatações de motor de renderização que alguns servidores usam
        STREAM_URL=$(echo "$STREAM_URL" | sed 's/^ffmpeg //i')

        M3U_ENTRY="#EXTINF:-1 tvg-id=\"$CHANNEL_ID\" tvg-name=\"$CHANNEL_NAME\" group-title=\"$CATEGORY_NAME\",$CHANNEL_NAME"

        # Salva o link na categoria original
        echo "$M3U_ENTRY" >> "$CATEGORY_FILE"
        echo "$STREAM_URL" >> "$CATEGORY_FILE"

        # Filtragem inteligente de canais do Brasil (Ignorando case-sensitive)
        UPPER_CHANNEL=$(echo "$CHANNEL_NAME" | tr '[:lower:]' '[:upper:]')
        UPPER_CATEGORY=$(echo "$CATEGORY_NAME" | tr '[:lower:]' '[:upper:]')

        IS_BRAZILIAN=0

        if [[ "$UPPER_CHANNEL" =~ (\(BR\)|\[BR\]|\{BR\}|^BR\ |^BR:|^BR-|\ BR\ |BRASIL|BRAZIL|PORTUGUESE|PT-BR) ]] || \
           [[ "$UPPER_CATEGORY" =~ (BRASIL|BRAZIL|PT-BR|PORTUGUESE|^BR\ |^BR-) ]]; then
            IS_BRAZILIAN=1
        fi

        if [ $IS_BRAZILIAN -eq 1 ]; then
            echo "[MIGRAÇÃO] Canal BR: '$CHANNEL_NAME'"
            echo "$M3U_ENTRY" >> "$BRAZIL_FILE"
            echo "$STREAM_URL" >> "$BRAZIL_FILE"
        fi

    done <<< "$CHANNELS"
    
    # Remove categoria local caso ela tenha ficado vazia
    if [ $(wc -l < "$CATEGORY_FILE") -eq 1 ]; then
        rm -f "$CATEGORY_FILE"
    fi

done <<< "$CATEGORIES"

# Remove arquivo do Brasil se nenhum canal nacional tiver sido capturado
if [ $(wc -l < "$BRAZIL_FILE") -eq 1 ]; then
    rm -f "$BRAZIL_FILE"
    echo "[INFO] Nenhum canal brasileiro localizado nesta varredura."
else
    echo "[SUCESSO] Playlist brasileira gerada em: $BRAZIL_FILE"
fi

# --- PASSO FINAL: Corrigir propriedade da pasta para o usuário real se rodado com sudo ---
if [ -n "$SUDO_USER" ]; then
    REAL_GROUP=$(id -gn "$SUDO_USER")
    chown -R "$SUDO_USER":"$REAL_GROUP" "$OUTPUT_DIR"
    echo "[INFO] Permissões da pasta '$OUTPUT_DIR' redefinidas para o usuário: $SUDO_USER"
fi

echo "[SUCESSO] Concluído! Arquivos extraídos salvos em: $OUTPUT_DIR"

# Garante que o script continue executável para a próxima vez
chmod +x "$0"
