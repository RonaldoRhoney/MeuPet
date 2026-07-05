// Job agendado (Vercel Cron, 1x/dia — ver vercel.json) que envia alertas
// push de "petshops perto de você" mesmo com o app fechado. Usa a
// service_role key porque precisa ler a linha de TODOS os inscritos,
// ignorando RLS (o cliente só consegue ver/gerenciar a própria inscrição).
//
// Throttle: só notifica de novo depois de 7 dias desde o último aviso pra
// aquele tutor, pra não virar spam.
const crypto = require('crypto');
const webpush = require('web-push');
const { createClient } = require('@supabase/supabase-js');

function isAuthorized(req){
  const cronSecret = process.env.CRON_SECRET;
  // fail-closed: sem CRON_SECRET configurado, NINGUÉM passa — nunca deixa
  // o endpoint aberto por esquecimento de configuração (achado de auditoria)
  if(!cronSecret) return false;
  const header = req.headers['authorization'] || '';
  const expected = `Bearer ${cronSecret}`;
  const a = Buffer.from(header);
  const b = Buffer.from(expected);
  // comparação em tempo constante — evita side-channel por diferença de
  // tempo de resposta revelando o segredo byte a byte
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = async (req, res) => {
  if (!isAuthorized(req)) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
  webpush.setVapidDetails(
    'mailto:contato@meupet.app',
    process.env.VAPID_PUBLIC_KEY,
    process.env.VAPID_PRIVATE_KEY
  );

  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();

  // lat/lng/city ficam na própria linha da inscrição (capturados no momento
  // em que o tutor ativou o alerta) — não em profiles, que é select-público;
  // guardar coordenada exata numa tabela pública seria vazamento de
  // localização (achado de auditoria de segurança, corrigido nesta feature)
  const { data: subs, error } = await supabase
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth, profile_id, last_notified_at, lat, lng, city')
    .or(`last_notified_at.is.null,last_notified_at.lt.${sevenDaysAgo}`);

  if (error) return res.status(500).json({ error: error.message });

  let sent = 0, removed = 0, skipped = 0;

  for (const sub of subs || []) {
    if (!sub.lat || !sub.lng) { skipped++; continue; }

    const { data: nearby } = await supabase.rpc('petshops_near', {
      p_lat: sub.lat, p_lng: sub.lng, p_radius_km: 10,
    });
    if (!nearby || !nearby.length) { skipped++; continue; }

    const payload = JSON.stringify({
      title: 'MeuPet',
      body: `${nearby.length} petshop${nearby.length > 1 ? 's' : ''} perto de você em ${sub.city || 'sua região'} 🐾`,
      url: '/#petshops',
    });

    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload
      );
      sent++;
      await supabase.from('push_subscriptions').update({ last_notified_at: new Date().toISOString() }).eq('id', sub.id);
    } catch (err) {
      // 404/410 = inscrição expirada/revogada no navegador — limpa do banco
      if (err.statusCode === 404 || err.statusCode === 410) {
        await supabase.from('push_subscriptions').delete().eq('id', sub.id);
        removed++;
      }
    }
  }

  res.status(200).json({ checked: subs?.length || 0, sent, removed, skipped });
};
