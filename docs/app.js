document.getElementById('add-channel-form').addEventListener('submit', async function(event) {
    event.preventDefault();

    const channelTitle = document.getElementById('channel-title').value.trim();
    const m3u8Link = document.getElementById('m3u8-link').value.trim();

    if (!channelTitle || !m3u8Link) {
        document.getElementById('response').innerText = 'Por favor, preencha todos os campos.';
        return;
    }

    const githubToken = 'SEU_NOVO_TOKEN_DE_ACESSO_PESSOAL'; // Substitua pelo seu novo token de acesso pessoal
    const repoOwner = 'listadobill';
    const repoName = 'tv';
    const filePath = 'canaisdosusuarios.m3u'; // Arquivo específico para adicionar os canais
    const branch = 'main';

    try {
        // Pegar o conteúdo atual do arquivo canaisdosusuarios.m3u
        const getFileResponse = await fetch(`https://api.github.com/repos/${repoOwner}/${repoName}/contents/${filePath}?ref=${branch}`, {
            headers: {
                'Authorization': `token ${githubToken}`,
                'Accept': 'application/vnd.github.v3+json'
            }
        });

        if (!getFileResponse.ok) {
            throw new Error('Erro ao acessar o arquivo do GitHub');
        }

        const fileData = await getFileResponse.json();
        const content = atob(fileData.content); // Decodifica o conteúdo de base64 para texto

        // Adicionar o novo canal ao conteúdo
        const updatedContent = `${content}\n#EXTINF:-1, ${channelTitle}\n${m3u8Link}\n`;

        // Re-codifica o conteúdo atualizado para base64
        const encodedContent = btoa(unescape(encodeURIComponent(updatedContent)));

        // Enviar o conteúdo atualizado de volta ao GitHub
        const updateResponse = await fetch(`https://api.github.com/repos/${repoOwner}/${repoName}/contents/${filePath}`, {
            method: 'PUT',
            headers: {
                'Authorization': `token ${githubToken}`,
                'Accept': 'application/vnd.github.v3+json'
            },
            body: JSON.stringify({
                message: `Added ${channelTitle} to canaisdosusuarios.m3u`,
                content: encodedContent,
                sha: fileData.sha,
                branch: branch
            })
        });

        if (updateResponse.ok) {
            document.getElementById('response').innerText = 'Canal adicionado com sucesso!';
        } else {
            throw new Error('Erro ao atualizar o arquivo');
        }
    } catch (error) {
        document.getElementById('response').innerText = `Erro: ${error.message}`;
    }
});
