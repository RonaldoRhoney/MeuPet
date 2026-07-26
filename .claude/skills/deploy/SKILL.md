---
description: Pipeline padrão pra editar e publicar mudanças no MeuPet — validar, sincronizar os HTMLs gêmeos, testar local, auditar segurança, commitar e subir pro GitHub + Vercel.
---

# Deploy do MeuPet

Sempre que terminar uma mudança em index.html/meupet.html/schema/api:

1. **Validar sintaxe JS** de cada `<script>` (`node -e` com `new Function(...)` em cada bloco).
2. **Sincronizar** `index.html` → `meupet.html` (são gêmeos, sempre idênticos — `cp` e `diff` pra conferir).
3. **Testar localmente**: `python3 -m http.server` + Playwright, contra o Supabase real (não mockar o banco). Limpar qualquer dado de teste criado ao final.
4. Se a mudança tocar schema/RLS/segurança/API nova: rodar o subagent `meupet-security` antes de continuar, e aplicar os achados relevantes antes do commit.
5. **Commit** (mensagem em português, curta, focada no "porquê" da mudança).
6. **Publicar no GitHub** (repo separado, populado via subtree a partir de `/home/rhoney`):
   ```
   cd /home/rhoney
   git subtree split --prefix=Documentos/MyApps/MeuPet -b meupet-root
   git push origin meupet-root:main --force
   git branch -D meupet-root
   ```
7. **Deploy**: `cd MeuPet && vercel --prod --yes`
8. **Verificar no ar**: `curl` na URL de produção confirmando que a mudança realmente está lá.

Não pular a etapa 3 (teste local) nem a 4 (auditoria quando aplicável) só pra economizar tempo — já pegaram bug real mais de uma vez.
