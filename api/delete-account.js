// Exclusão de conta — exigência do Google Play (Data Safety) desde 2022:
// todo app com criação de conta precisa oferecer um jeito de apagar os
// dados, inclusive por um recurso web (não só dentro do app). Usa a
// service_role só aqui, no servidor, pra chamar auth.admin.deleteUser —
// o cliente nunca pode apagar sua própria linha em auth.users diretamente.
//
// A cascata é toda feita pelo banco: profiles referencia auth.users(id)
// on delete cascade, e quase todas as outras tabelas (pets, posts,
// comments, likes, feedback_*, adoption_listings, push_subscriptions,
// profile_private_info) referenciam profiles(id) on delete cascade —
// apagar o usuário já limpa tudo isso automaticamente.
const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method not allowed' });
  }

  const authHeader = req.headers['authorization'] || '';
  const token = authHeader.replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'missing token' });

  const supabaseAdmin = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  // valida o token de acesso do próprio usuário — garante que a exclusão
  // só afeta a conta de quem está fazendo a chamada, nunca outra
  const { data: { user }, error: userError } = await supabaseAdmin.auth.getUser(token);
  if (userError || !user) return res.status(401).json({ error: 'invalid token' });

  const { error: deleteError } = await supabaseAdmin.auth.admin.deleteUser(user.id);
  if (deleteError) return res.status(500).json({ error: deleteError.message });

  res.status(200).json({ success: true });
};
