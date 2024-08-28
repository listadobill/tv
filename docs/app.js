document.getElementById('add-channel-form').addEventListener('submit', async function(event) {
    event.preventDefault();

    const channelTitle = document.getElementById('channel-title').value;
    const m3u8Link = document.getElementById('m3u8-link').value;

    const githubToken = 'SEU_GITHUB_TOKEN'; // Substitua pelo seu token de acesso pessoal
    const repoOwner = 'listadobill';
    const repoName = 'tv';
    const filePath = 'caminho/para/seu/arquivo.m3u'; // Substitua pelo caminho exato do arquivo .m3u no seu repositório
    const branch = 'main';

    try {
        // Pegar o conteúdo atual do arquivo .m3u
        const getFileResponse = await fetch(`https://api.github.com/repos/${repoOwner}/${repoName}/contents/${filePath}?ref=${branch}`, {
            headers: {
                'Authorization': `token ${githubToken}`,
                'Accept': 'application/vnd.github.v3+json'
            }
        });
        const fileData = await getFileResponse.json();
        const content = atob(fileData.content);

        // Adicionar o novo canal ao conteúdo
        const updatedContent = `${content}\n#EXTINF:-1, ${channelTitle}\n${m3u8Link}\n`;

        // Enviar o conteúdo atualizado de volta ao GitHub
        const updateResponse = await fetch(`https://api.github.com/repos/${repoOwner}/${repoName}/contents/${filePath}`, {
            method: 'PUT',
            headers: {
                'Authorization': `token ${githubToken}`,
                'Accept': 'application/vnd.github.v3+json'
            },
            body: JSON.stringify({
                message: `Added ${channelTitle} to the .m3u`,
                content: btoa(updatedContent),
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
