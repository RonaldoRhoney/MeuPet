// Proxy server-side pra YouTube Data API v3 — busca vídeos reais de pets
// engraçados por tópico fixo (não aceita query livre do cliente: um endpoint
// sem auth que repassasse qualquer string pro Google viraria um jeito
// gratuito de qualquer um gastar nossa cota de API, então só aceitamos um
// enum pequeno e pré-definido de tópicos).
//
// A chave (YOUTUBE_API_KEY) fica só aqui no servidor — nunca é enviada pro
// navegador, diferente da anon key do Supabase (que é intencionalmente
// pública). videoEmbeddable=true + safeSearch=strict filtram por conteúdo
// que o dono permite incorporar e é seguro pra família.
const TOPIC_QUERIES = {
  gatos: 'gatos engraçados',
  cachorros: 'cachorros engraçados',
  compilacao: 'pets engraçados compilação',
};

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'method not allowed' });
  }

  const topic = String(req.query.topic || '');
  const query = TOPIC_QUERIES[topic];
  if (!query) {
    return res.status(400).json({ error: 'topic inválido — use: ' + Object.keys(TOPIC_QUERIES).join(', ') });
  }

  const apiKey = process.env.YOUTUBE_API_KEY;
  if (!apiKey) {
    return res.status(500).json({ error: 'YOUTUBE_API_KEY não configurada' });
  }

  const url = new URL('https://www.googleapis.com/youtube/v3/search');
  url.searchParams.set('part', 'snippet');
  url.searchParams.set('type', 'video');
  url.searchParams.set('videoEmbeddable', 'true');
  url.searchParams.set('safeSearch', 'strict');
  url.searchParams.set('maxResults', '20');
  url.searchParams.set('q', query);
  url.searchParams.set('key', apiKey);

  try {
    const ytRes = await fetch(url);
    if (!ytRes.ok) {
      const body = await ytRes.text();
      console.error('MeuPet: YouTube Data API falhou', ytRes.status, body);
      return res.status(502).json({ error: 'YouTube Data API indisponível' });
    }
    const data = await ytRes.json();
    const pool = (data.items || [])
      .filter(item => /^[A-Za-z0-9_-]{11}$/.test(item.id?.videoId || ''))
      .map(item => ({
        videoId: item.id.videoId,
        title: item.snippet?.title || '',
        thumbnail: item.snippet?.thumbnails?.medium?.url || item.snippet?.thumbnails?.default?.url || null,
        channelTitle: item.snippet?.channelTitle || '',
      }));

    // escolhe 1 vídeo do "pool" de forma determinística por dia — todo
    // mundo vê o mesmo vídeo no mesmo dia (bom pro cache da CDN), mas ele
    // troca sozinho a cada 24h assim que o cache expira e o índice avança
    const dayIndex = Math.floor(Date.now() / 86400000);
    const videos = pool.length ? [pool[dayIndex % pool.length]] : [];

    // cache de 24h na CDN da Vercel — expira junto com a troca diária de
    // índice, e mantém o uso de cota do Google bem baixo mesmo sob tráfego alto
    res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=86400, stale-while-revalidate=172800');
    res.status(200).json({ videos });
  } catch (err) {
    console.error('MeuPet: falha ao chamar YouTube Data API', err);
    res.status(502).json({ error: 'falha ao buscar vídeos' });
  }
};
