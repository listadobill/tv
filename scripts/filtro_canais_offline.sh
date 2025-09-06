#!/bin/bash
set -e

# ==============================
# 🔥 COLE SUA LISTA M3U AQUI 🔥
# ==============================
# Exemplo:
# #EXTM3U
# #EXTINF:-1, Canal Teste
# http://meu-servidor.com:8080/live/teste.m3u8
# #EXTINF:-1, Outro Canal
# http://meu-servidor.com:8080/live/outro.m3u8
# ==============================
M3U_LISTA=$(cat << 'EOF'


#EXTM3U
# Cole aqui suas linhas de canais
# Por exemplo:
#EXTINF:-1, Canal Teste
http://exemplo.com/stream1.m3u8
#EXTINF:-1, Outro Canal
http://exemplo.com/stream2.m3u8


EOF
)

# Arquivos temporários
INPUT_FILE="entrada.m3u"
OUTPUT_FILE="lista_filtrada.m3u"
PY_SCRIPT="filtrar_m3u_temp.py"

# Salva a lista colada em arquivo
echo "$M3U_LISTA" > "$INPUT_FILE"

echo "🔧 Instalando dependências via apt..."
sudo apt update -y
sudo apt install -y python3 python3-requests

# Criar script Python temporário
cat > "$PY_SCRIPT" << 'EOF'
#!/usr/bin/env python3
import requests
import time
import datetime
import os

INPUT_FILE = "entrada.m3u"
OUTPUT_FILE = "lista_filtrada.m3u"
TENTATIVAS = 5
TIMEOUT = 5

def testar_url(url, tentativas=TENTATIVAS, timeout=TIMEOUT):
    for i in range(tentativas):
        try:
            r = requests.head(url, timeout=timeout, allow_redirects=True)
            if r.status_code < 400:
                return True
        except Exception:
            time.sleep(1)
    return False

def carregar_lista(arquivo):
    with open(arquivo, "r", encoding="utf-8", errors="ignore") as f:
        linhas = f.read().splitlines()
    canais = []
    for i in range(len(linhas)):
        if linhas[i].startswith("#EXTINF"):
            if i+1 < len(linhas):
                canais.append((linhas[i], linhas[i+1].strip()))
    return canais

def salvar_lista(canais, arquivo):
    hoje = datetime.datetime.now().strftime("%d/%m/%Y")
    with open(arquivo, "w", encoding="utf-8") as f:
        f.write("#EXTM3U\n")
        f.write(f"#EXTINF:-1, Lista atualizada em {hoje}\n")
        f.write("http://atualizacao.local/\n")
        for info, url in canais:
            f.write(info + "\n")
            f.write(url + "\n")

def main():
    if not os.path.exists(INPUT_FILE):
        print(f"❌ Arquivo {INPUT_FILE} não encontrado!")
        return
    
    print("🔎 Carregando lista...")
    canais = carregar_lista(INPUT_FILE)
    ativos = []

    for info, url in canais:
        nome = info.split(",")[-1].strip()
        print(f"Testando: {nome} -> {url}")
        if testar_url(url):
            print("✅ ONLINE")
            ativos.append((info, url))
        else:
            print("❌ OFFLINE")

    # Ordenar alfabeticamente pelo nome
    ativos.sort(key=lambda x: x[0].split(",")[-1].strip().lower())

    salvar_lista(ativos, OUTPUT_FILE)
    print(f"\n✅ Nova lista salva em: {OUTPUT_FILE}")

if __name__ == "__main__":
    main()
EOF

# Executar o script Python
echo "🚀 Filtrando lista IPTV..."
python3 "$PY_SCRIPT"

# Remover script temporário
rm -f "$PY_SCRIPT"

echo "🎉 Processo concluído! Veja o arquivo $OUTPUT_FILE"
