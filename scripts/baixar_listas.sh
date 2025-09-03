#!/bin/bash
# ==============================================================
# Script: baixar_listas.sh
# Finalidade: Baixar listas M3U para a pasta ~/Downloads/listas
# Sistema: Debian ou derivados
# ==============================================================

# --- Instala dependências necessárias ---
sudo apt update -y
sudo apt install -y curl wget

# --- Define pasta destino ---
DESTINO="$HOME/Downloads/listas"

# --- Cria a pasta caso não exista ---
mkdir -p "$DESTINO"

################ --- Campo para colar as listas ---#################
############## COLE SUAS LISTAS ENTRE EOF e EOF, UMA POR LINHA ######################################
LISTAS=$(cat <<EOF














EOF
)

####################################################################################################################################################
# --- Baixa listas uma por uma ---
echo "📥 Baixando listas para: $DESTINO"
i=1
for url in $LISTAS; do
    nome="lista${i}.m3u8"
    echo "➡️  Baixando $url"
    wget -q --show-progress -O "$DESTINO/$nome" "$url"
    if [[ $? -eq 0 ]]; then
        echo "✅ Salvo como $nome"
    else
        echo "❌ Falha ao baixar: $url"
    fi
    ((i++))
done

echo "-----------------------------------------"
echo "🎉 Todas as listas foram processadas!"
echo "📂 Arquivos salvos em: $DESTINO"
