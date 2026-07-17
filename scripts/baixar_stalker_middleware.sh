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

# Configurações
PORTAL_URL="http://192.142.44.56/c"
MAC_ADDRESS="00:1A:79:21:D5:02"

# Pasta de saída onde todas as categorias e o arquivo do Brasil serão salvos
OUTPUT_DIR="canais_extraidos"
mkdir -p "$OUTPUT_DIR"

# User-Agent para simular um dispositivo MAG250
USER_AGENT="Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"
X_USER_AGENT="Model: MAG250; Link: WiFi"

# Função para gerar um valor aleatório (usado para 'random' no handshake)
generate_random_value() {
    head /dev/urandom | tr -dc A-Za-z0-9 | head -c 40
}

# Função para gerar o device_id (SHA256 do MAC)
generate_device_id() {
    echo -n "$MAC_ADDRESS" | sha256sum | awk '{print toupper(substr($1, 1, 64))}'
}

# Função para gerar o serial (MD5 do MAC, primeiros 13 caracteres)
generate_serial() {
    echo -n "$MAC_ADDRESS" | md5sum | awk '{print toupper(substr($1, 1, 13))}'
}

# Gerar valores necessários
RANDOM_VALUE=$(generate_random_value)
DEVICE_ID=$(generate_device_id)
SERIAL=$(generate_serial)

# Extrair host do PORTAL_URL para o cabeçalho Host
PORTAL_HOST=$(echo "$PORTAL_URL" | sed -e 's/^http:\/\///' -e 's/\/.*$//')

# --- PASSO 1: HANDSHAKE para obter o token ---
echo "[INFO] Realizando handshake com o portal..."

HANDSHAKE_URL="${PORTAL_URL}/server/load.php?type=stb&action=handshake&JsHttpRequest=1-xml"

HANDSHAKE_RESPONSE=$(curl -s -X GET \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-User-Agent: ${X_USER_AGENT}" \
    -H "Referer: ${PORTAL_URL}/index.html" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Pragma: no-cache" \
    -H "Host: ${PORTAL_HOST}" \
    -H "Connection: Close" \
    -H "Accept-Encoding: gzip, deflate" \
    --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; random=${RANDOM_VALUE}" \
    "${HANDSHAKE_URL}")

TOKEN=$(echo "$HANDSHAKE_RESPONSE" | jq -r ".js.token")

if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
    echo "[ERRO] Falha ao obter o token de handshake. Resposta: $HANDSHAKE_RESPONSE"
    exit 1
fi

echo "[INFO] Token obtido: $TOKEN"

# --- PASSO 2: GET PROFILE para autenticação completa ---
echo "[INFO] Obtendo perfil do dispositivo..."

PROFILE_URL="${PORTAL_URL}/server/load.php?type=stb&action=get_profile&JsHttpRequest=1-xml"
SIGNATURE=$(echo -n "${MAC_ADDRESS}${SERIAL}${DEVICE_ID}${DEVICE_ID}" | sha256sum | awk '{print toupper($1)}')

PROFILE_RESPONSE=$(curl -s -X GET \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-User-Agent: ${X_USER_AGENT}" \
    -H "Referer: ${PORTAL_URL}/index.html" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Pragma: no-cache" \
    -H "Host: ${PORTAL_HOST}" \
    -H "Connection: Close" \
    -H "Accept-Encoding: gzip, deflate" \
    --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
    --data-urlencode "sn=${SERIAL}" \
    --data-urlencode "device_id=${DEVICE_ID}" \
    --data-urlencode "device_id2=${DEVICE_ID}" \
    --data-urlencode "signature=${SIGNATURE}" \
    --data-urlencode "metrics={\"mac\":\"${MAC_ADDRESS}\",\"sn\":\"${SERIAL}\",\"type\":\"STB\",\"model\":\"MAG250\",\"uid\":\"\",\"random\":\"${RANDOM_VALUE}\"}" \
    "${PROFILE_URL}")

if ! echo "$PROFILE_RESPONSE" | jq -e "." > /dev/null; then
    echo "[AVISO] Resposta de perfil inválida ou vazia. Continuando... Resposta: $PROFILE_RESPONSE"
fi

# --- PASSO 3: OBTER CATEGORIAS DE CANAIS ---
echo "[INFO] Obtendo categorias de canais..."

CATEGORIES_URL="${PORTAL_URL}/server/load.php?type=itv&action=get_genres&JsHttpRequest=1-xml"

CATEGORIES_RESPONSE=$(curl -s -X GET \
    -H "User-Agent: ${USER_AGENT}" \
    -H "X-User-Agent: ${X_USER_AGENT}" \
    -H "Referer: ${PORTAL_URL}/index.html" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Pragma: no-cache" \
    -H "Host: ${PORTAL_HOST}" \
    -H "Connection: Close" \
    -H "Accept-Encoding: gzip, deflate" \
    --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
    "${CATEGORIES_URL}")

CATEGORIES=$(echo "$CATEGORIES_RESPONSE" | jq -c ".js[]")

if [ -z "$CATEGORIES" ]; then
    echo "[ERRO] Falha ao obter categorias de canais. Resposta: $CATEGORIES_RESPONSE"
    exit 1
fi

# --- PASSO 4: OBTER CANAIS POR CATEGORIA E SEPARAR ---
echo "[INFO] Obtendo canais e separando em arquivos..."

# Criando a lista unificada para canais Brasileiros
BRAZIL_FILE="${OUTPUT_DIR}/Brasil.m3u"
echo "#EXTM3U" > "$BRAZIL_FILE"

while IFS= read -r category;
do
    CATEGORY_ID=$(echo "$category" | jq -r ".id")
    CATEGORY_NAME=$(echo "$category" | jq -r ".title")

    # Limpar caracteres inválidos do nome da categoria para salvar o arquivo de forma segura
    SAFE_CATEGORY_NAME=$(echo "$CATEGORY_NAME" | sed 's/[^A-Za-z0-9_-]/_/g')
    CATEGORY_FILE="${OUTPUT_DIR}/${SAFE_CATEGORY_NAME}.m3u"
    
    echo "#EXTM3U" > "$CATEGORY_FILE"

    echo "[INFO] Processando categoria: $CATEGORY_NAME (ID: $CATEGORY_ID)"

    CHANNELS_URL="${PORTAL_URL}/server/load.php?type=itv&action=get_ordered_list&genre=${CATEGORY_ID}&JsHttpRequest=1-xml"

    CHANNELS_RESPONSE=$(curl -s -X GET \
        -H "User-Agent: ${USER_AGENT}" \
        -H "X-User-Agent: ${X_USER_AGENT}" \
        -H "Referer: ${PORTAL_URL}/index.html" \
        -H "Accept-Language: en-US,en;q=0.5" \
        -H "Pragma: no-cache" \
        -H "Host: ${PORTAL_HOST}" \
        -H "Connection: Close" \
        -H "Accept-Encoding: gzip, deflate" \
        --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
        "${CHANNELS_URL}")

    CHANNELS=$(echo "$CHANNELS_RESPONSE" | jq -c ".js.data[]")

    if [ -z "$CHANNELS" ]; then
        echo "[AVISO] Nenhum canal encontrado para a categoria: $CATEGORY_NAME"
        rm -f "$CATEGORY_FILE"
        continue
    fi

    while IFS= read -r channel;
    do
        CHANNEL_NAME=$(echo "$channel" | jq -r ".name")
        CHANNEL_CMD=$(echo "$channel" | jq -r ".cmd")
        CHANNEL_ID=$(echo "$channel" | jq -r ".id")

        if [ -z "$CHANNEL_CMD" ] || [ "$CHANNEL_CMD" == "null" ]; then
            echo "[AVISO] Canal '$CHANNEL_NAME' (ID: $CHANNEL_ID) sem CMD. Pulando."
            continue
        fi

        # --- PASSO 5: GERAR LINK DE STREAM ---
        CREATE_LINK_URL="${PORTAL_URL}/server/load.php?type=itv&action=create_link&cmd=$(echo "$CHANNEL_CMD" | jq -sRr @uri)&JsHttpRequest=1-xml"

        STREAM_RESPONSE=$(curl -s -X GET \
            -H "User-Agent: ${USER_AGENT}" \
            -H "X-User-Agent: ${X_USER_AGENT}" \
            -H "Referer: ${PORTAL_URL}/index.html" \
            -H "Accept-Language: en-US,en;q=0.5" \
            -H "Pragma: no-cache" \
            -H "Host: ${PORTAL_HOST}" \
            -H "Connection: Close" \
            -H "Accept-Encoding: gzip, deflate" \
            --cookie "mac=${MAC_ADDRESS}; stb_lang=en; timezone=Europe/Paris; token=${TOKEN}; random=${RANDOM_VALUE}" \
            "${CREATE_LINK_URL}")

        STREAM_URL=$(echo "$STREAM_RESPONSE" | jq -r ".js.url // .js.cmd")

        if [ -z "$STREAM_URL" ] || [ "$STREAM_URL" == "null" ]; then
            echo "[AVISO] Falha ao obter URL de stream para '$CHANNEL_NAME'. Resposta: $STREAM_RESPONSE. Pulando."
            continue
        fi

        # Limpar o prefixo 'ffmpeg ' se o servidor retornar assim
        STREAM_URL=$(echo "$STREAM_URL" | sed 's/^ffmpeg //i')

        # Estruturar a linha m3u
        M3U_ENTRY="#EXTINF:-1 tvg-id=\"$CHANNEL_ID\" tvg-name=\"$CHANNEL_NAME\" group-title=\"$CATEGORY_NAME\",$CHANNEL_NAME"

        # 1. Gravar na lista da categoria correspondente
        echo "$M3U_ENTRY" >> "$CATEGORY_FILE"
        echo "$STREAM_URL" >> "$CATEGORY_FILE"

        # 2. FILTRAGEM DE CANAIS BRASILEIROS (Com Regex Avançado)
        UPPER_CHANNEL=$(echo "$CHANNEL_NAME" | tr '[:lower:]' '[:upper:]')
        UPPER_CATEGORY=$(echo "$CATEGORY_NAME" | tr '[:lower:]' '[:upper:]')

        IS_BRAZILIAN=0

        # Regras de captura focadas em (BR) nome do canal, BR - BRASIL e variações comuns
        if [[ "$UPPER_CHANNEL" =~ (\(BR\)|\[BR\]|\{BR\}|^BR\ |^BR:|^BR-|\ BR\ |BRASIL|BRAZIL|PORTUGUESE|PT-BR) ]] || \
           [[ "$UPPER_CATEGORY" =~ (BRASIL|BRAZIL|PT-BR|PORTUGUESE|^BR\ |^BR-) ]]; then
            IS_BRAZILIAN=1
        fi

        if [ $IS_BRAZILIAN -eq 1 ]; then
            echo "[MIGRAÇÃO] Canal Brasileiro detectado: '$CHANNEL_NAME'"
            echo "$M3U_ENTRY" >> "$BRAZIL_FILE"
            echo "$STREAM_URL" >> "$BRAZIL_FILE"
        fi

    done <<< "$CHANNELS"
    
    # Se a categoria terminar vazia (apenas com o cabeçalho #EXTM3U), apaga para limpar a pasta
    if [ $(wc -l < "$CATEGORY_FILE") -eq 1 ]; then
        rm -f "$CATEGORY_FILE"
    fi

done <<< "$CATEGORIES"

# Se nenhum canal foi enviado para a lista do Brasil, removemos o arquivo vazio
if [ $(wc -l < "$BRAZIL_FILE") -eq 1 ]; then
    rm -f "$BRAZIL_FILE"
    echo "[INFO] Nenhum canal brasileiro foi identificado."
else
    echo "[SUCESSO] Lista unificada de canais brasileiros salva em: $BRAZIL_FILE"
fi

# --- PASSO FINAL: Restaurar propriedade da pasta ao usuário real ---
if [ -n "$SUDO_USER" ]; then
    echo "[INFO] Ajustando permissões da pasta '$OUTPUT_DIR' para o usuário: $SUDO_USER"
    # Obtém também o grupo principal do usuário real de forma dinâmica
    REAL_GROUP=$(id -gn "$SUDO_USER")
    chown -R "$SUDO_USER":"$REAL_GROUP" "$OUTPUT_DIR"
fi

echo "[SUCESSO] Processo concluído! Os arquivos estão na pasta: $OUTPUT_DIR"

# Garante que o script continue executável nas próximas vezes
chmod +x "$0"
