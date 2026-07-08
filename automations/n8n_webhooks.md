# MeuPet — URLs dos webhooks n8n (preencher após ativar cada workflow)

Veja `SETUP.md` para o passo a passo completo. Preencha as URLs reais aqui
conforme for ativando cada workflow no n8n, e use essas mesmas URLs ao
configurar os Database Webhooks no Supabase.

| # | Automação            | Tabela / Evento              | URL do webhook n8n |
|---|-----------------------|-------------------------------|---------------------|
| 1 | Bug report            | `reports` INSERT               | _(preencher)_       |
| 2 | Novo usuário           | `profiles` INSERT              | _(preencher)_       |
| 3 | Marco de curtidas      | `likes` INSERT                 | _(preencher)_       |
| 4 | Nova adoção            | `adoption_listings` INSERT     | _(preencher)_       |
| 5 | Assinatura Premium     | `subscriptions` INSERT         | _(preencher)_       |
| 6 | Relatório diário       | agendado, 8h — sem webhook     | —                    |
| 7 | Petshop parceiro       | `petshops` UPDATE              | _(preencher)_       |

**Nunca coloque a service_role key ou o token do Telegram neste arquivo** —
só URLs de webhook (que não são segredo, servem só pra receber POST).
