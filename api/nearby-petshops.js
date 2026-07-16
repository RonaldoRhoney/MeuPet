// Proxy server-side pra Overpass API (OpenStreetMap) — busca petshops e
// veterinários reais perto de uma coordenada.
//
// Por que existe: chamar a Overpass API direto do navegador esbarra em CORS
// de forma persistente nos espelhos públicos gratuitos (lz4.overpass-api.de,
// overpass.private.coffee, overpass-api.de) — não é intermitência, os 3
// bloqueiam ou não respondem a requisições cross-origin de navegador de
// forma confiável. Chamada servidor-a-servidor não sofre restrição de CORS
// (CORS é uma regra do navegador, não do protocolo HTTP em si), então este
// proxy resolve o problema na raiz: o app só fala com nossa própria API
// (mesma origem, sem CORS), e É AQUI que tentamos os espelhos em sequência.
//
// Endpoint é público/sem auth de propósito (busca de petshop é uma feature
// anônima do app, não exige login) — a mitigação de abuso é: (1) snap de
// precisão da coordenada, que faz o cache da CDN funcionar de verdade pra
// coordenadas "quase iguais" em vez de nunca bater cache; (2) validação de
// range em lat/lng/radiusKm, barrando request-lixo antes de gastar uma
// chamada real aos mirrors.
const OVERPASS_MIRRORS = [
  'https://overpass-api.de/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
];

// orçamento total precisa caber sob o timeout de função da Vercel (10s no
// plano Hobby) E sob o abort de 9s do cliente — 3 mirrors x 3s = 9s no pior
// caso, com folga
const PER_MIRROR_TIMEOUT_MS = 3000;

async function fetchWithTimeout(url, body, timeoutMs){
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method: 'POST',
      body,
      signal: controller.signal,
      // identifica o app pro Overpass — sem isso, tráfego com UA genérico
      // é mais sujeito a rate-limit/bloqueio sob carga
      headers: { 'User-Agent': 'MeuPet/1.0 (https://meupet-zeta.vercel.app)' },
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

module.exports = async (req, res) => {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'method not allowed' });
  }

  const latRaw = parseFloat(req.query.lat);
  const lngRaw = parseFloat(req.query.lng);
  const radiusKmRaw = parseFloat(req.query.radiusKm) || 8;

  if (!Number.isFinite(latRaw) || !Number.isFinite(lngRaw) ||
      latRaw < -90 || latRaw > 90 || lngRaw < -180 || lngRaw > 180) {
    return res.status(400).json({ error: 'lat/lng inválidos ou fora de alcance' });
  }
  const radiusKm = Math.min(Math.max(radiusKmRaw, 0.5), 20);

  // snap de precisão (~110m) — evita que cada casa decimal vire uma chave de
  // cache diferente na CDN (o que na prática nunca bateria cache), e evita
  // logar/guardar a coordenada exata do usuário sem necessidade (LGPD)
  const lat = Math.round(latRaw * 1000) / 1000;
  const lng = Math.round(lngRaw * 1000) / 1000;

  const radiusM = Math.round(radiusKm * 1000);
  // `way` cobre locais mapeados como área/prédio (comum pra clínicas maiores)
  // — junto com `out center`, que dá lat/lng do centro geométrico da área,
  // já que ways não têm lat/lon direto como node
  const query = `[out:json][timeout:15];(
    node["shop"="pet"](around:${radiusM},${lat},${lng});
    way["shop"="pet"](around:${radiusM},${lat},${lng});
    node["amenity"="veterinary"](around:${radiusM},${lat},${lng});
    way["amenity"="veterinary"](around:${radiusM},${lat},${lng});
    node["shop"="grooming"](around:${radiusM},${lat},${lng});
  );out center 30;`;

  let data = null, lastErr = null;
  for (const mirror of OVERPASS_MIRRORS) {
    try {
      data = await fetchWithTimeout(mirror, query, PER_MIRROR_TIMEOUT_MS);
      break;
    } catch (err) {
      lastErr = err;
    }
  }

  if (!data) {
    return res.status(502).json({ error: 'Todos os espelhos Overpass falharam: ' + (lastErr?.message || 'erro desconhecido') });
  }

  const elements = (data.elements || [])
    .map(el => ({ ...el, lat: el.lat ?? el.center?.lat, lon: el.lon ?? el.center?.lon }))
    .filter(el => el.lat != null && el.lon != null)
    .map(el => {
      const t = el.tags || {};
      const addrParts = [t['addr:street'], t['addr:housenumber']].filter(Boolean).join(', ');
      const kind = t.amenity === 'veterinary' ? 'Veterinário' : (t.shop === 'grooming' ? 'Banho e Tosa' : 'Petshop');
      return {
        name: t.name || kind,
        kind,
        address: addrParts || t['addr:full'] || null,
        phone: t.phone || t['contact:phone'] || null,
        website: t.website || t['contact:website'] || null,
        openingHours: t.opening_hours || null,
        lat: el.lat, lng: el.lon,
      };
    });

  // cache de 10 min na CDN da Vercel — combinado com o snap de precisão
  // acima, agora bate cache de verdade pra coordenadas próximas
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=600, stale-while-revalidate=1800');
  res.status(200).json({ elements });
};
