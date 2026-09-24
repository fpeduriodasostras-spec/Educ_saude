# Supabase — nova regra de permissões a partir de 30/10/2026

E-mail oficial recebido em 23/09/2026 (conta `fp.edu.riodasostras@gmail.com`).

## O que muda

A partir de **30/10/2026**, tabela NOVA criada no esquema `public` **não ganha
mais acesso automático** à API de Dados. Sem um `GRANT` explícito, o app recebe
"permission denied" ao tentar ler/gravar nela.

- **Tabelas existentes: nada muda.** Os apps continuam funcionando.
- **Migrations contam:** qualquer migration que crie tabela sem os GRANTs deixa
  a tabela inacessível pela API. Isso pega **projeto novo, branch de preview e
  "reset do banco"** — exatamente o caminho da expansão para os ~5 contratos
  (EXPANSAO-5-CONTRATOS.md) e qualquer reinstalação da baseline.

## Onde isso pega a F.P. Vieira

| Banco | Projeto | Risco |
|---|---|---|
| Educação `lgdnuy…` | FPV-Campo | tabelas atuais OK; **novas tabelas e reinstalações da baseline `0001` precisam de GRANT** |
| Fiscalização `irprgd…` | FPV-FISCALIZACAO | idem |
| Saúde `pbdufx…` | FPVIEIRA-SAUDE | idem — a instalação usa `0000`+`0001`; replicar o app num contrato novo depois de 30/10 SEM os GRANTs = app nasce morto |

## O modelo de GRANT (colar na MESMA migration que cria a tabela)

```sql
-- padrão do projeto: anon só enxerga o que a RLS liberar; gravação é de
-- usuário logado; service_role é das rotinas/n8n
grant select on public.NOME_DA_TABELA to anon;
grant select, insert, update, delete on public.NOME_DA_TABELA to authenticated;
grant select, insert, update, delete on public.NOME_DA_TABELA to service_role;
```

⚠️ **GRANT não substitui RLS.** O GRANT abre a porta da API; quem decide o que
cada um vê/grava continua sendo a RLS (as policies). As duas camadas convivem.

## O que fazer (proposta — SQL em produção passa pelo Renan antes)

1. **Agora, sem pressa:** nada quebra nos bancos atuais.
2. **Antes de 30/10:** acrescentar os GRANTs às migrations que criam tabelas
   (`0001_baseline.sql` e seguintes) nos três repositórios, para que qualquer
   instalação nova continue funcionando. Uma migration nova `00XX_grants.sql`
   idempotente também vale para os bancos vivos, por segurança.
3. **Conferir a lista de tabelas expostas** nas configurações da API de Dados
   de cada projeto (painel do Supabase), como o e-mail recomenda.
4. Registrar no `CLAUDE.md` dos repos: "toda migration que cria tabela inclui
   os GRANTs no mesmo arquivo" — vira regra de projeto.
