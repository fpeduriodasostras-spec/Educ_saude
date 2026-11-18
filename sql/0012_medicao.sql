-- =====================================================================
-- 0012 · A MEDIÇÃO PASSA A MORAR NO BANCO
-- Banco da VPS (supabase.arkaisolutions.app.br) · PROPOSTA de 14/11/2026
-- ⚠️ NÃO APLICADA. SQL em produção passa por revisão antes (Renan/Leony).
--
-- Por quê: o Painel do Medidor produz trabalho que hoje fica espalhado —
-- lançamentos (código EMOP + conta por O.S.) só dentro do painel no Claude,
-- itens do contrato em arquivos JSON, aprovadas/glosadas em CSVs no servidor
-- (/root/fpv-mestra/aprovadas_*.csv) e o período de cada medição digitado à mão.
-- Aqui isso vira 4 tabelas, para Educação e Saúde, sem tocar no que existe:
--
--   contrato_item       os itens de cada contrato (código, preço, qtd, saldo)
--   medicao             cada medição: número, período, situação, valor oficial
--   medicao_os          cada O.S. dentro de uma medição: lançada/pulada,
--                       fotos e legenda do relatório, resultado da fiscalização
--   medicao_lancamento  a memória de cálculo: item + conta + quantidade
--
-- O que NÃO muda: nenhuma coluna nova em os_campo, nenhuma policy existente,
-- nenhum dado existente. O app de campo continua igual.
--
-- Permissões (regra do Supabase de 30/10/2026 — tabela nova sem GRANT fica
-- inacessível pela API; ver docs/SUPABASE-GRANTS-30-10.md):
--   · anon: NENHUM acesso (dado de medição não é público)
--   · authenticated: GRANT completo, mas quem decide é a RLS:
--       - contrato_item: qualquer login LÊ (preços do contrato); só a equipe
--         de medição altera
--       - medicao / medicao_os / medicao_lancamento: só a equipe de medição
--         (função fpv_equipe_medicao — UMA lista de e-mails, não 20 cópias)
--   · service_role: tudo (rotinas, n8n, scripts da VPS)
-- Medição FECHADA é intocável: nada de lançar, mudar ou apagar O.S. nela.
--
-- Aplicar fora do horário de campo: as chaves estrangeiras para os_campo
-- pedem uma trava rápida (frações de segundo) nessa tabela.
-- Idempotente: pode rodar duas vezes sem estragar.
-- Dados iniciais (itens dos contratos + medições abertas): 0012b_medicao_dados.sql
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Funções de apoio
-- ---------------------------------------------------------------------
-- Quem mede. Para incluir/tirar alguém, muda só aqui (create or replace).
create or replace function public.fpv_equipe_medicao() returns boolean
language sql stable
set search_path = public
as $$
  select coalesce(auth.jwt() ->> 'email', '') = any (array[
    'edmar@fpv.app',   -- medidor
    'lucas@fpv.app',   -- gestão
    'rafael@fpv.app',  -- gestão
    'renan@fpv.app',   -- gestão / sistema
    'leony@fpv.app'    -- engenheiro (se o login existir)
  ]);
$$;

-- carimbo de "atualizado_em"
create or replace function public.fpv_carimba_atualizado() returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. contrato_item — os itens de cada contrato
-- ---------------------------------------------------------------------
create table if not exists public.contrato_item (
  id                   bigint generated always as identity primary key,
  contrato             text    not null check (contrato in ('Educação', 'Saúde')),  -- mesmo texto de os_campo.contrato
  item                 text,             -- nº do item na planilha (ex.: 15.31)
  item_arp             text,             -- Saúde: "ITEM REF. A ARP" (ex.: 15.1)
  codigo_emop          text    not null, -- ex.: 15.005.0215-A (ou 20154 na mão de obra)
  descricao            text    not null,
  unid                 text    not null,
  secao                text,
  ordem                integer,          -- ordem na planilha: a memória de cálculo sai nela
  qtd_contratada       numeric check (qtd_contratada is null or qtd_contratada >= 0),
  preco_sem_bdi        numeric check (preco_sem_bdi is null or preco_sem_bdi >= 0),
  preco_com_bdi        numeric not null check (preco_com_bdi >= 0),
  -- o que já foi medido ANTES de a medição morar no banco (acumulado oficial das
  -- planilhas) e até qual medição isso vai; o saldo soma os lançamentos depois dela
  qtd_medida_anterior  numeric not null default 0,
  medida_anterior_ate  integer,          -- nº da medição (ex.: 9 = "até a MED 09")
  ativo                boolean not null default true,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now(),
  unique (contrato, codigo_emop)
);
comment on table public.contrato_item is 'Itens EMOP de cada contrato (preço c/ BDI, qtd contratada, medido antes do sistema). Painel do Medidor.';

-- ---------------------------------------------------------------------
-- 3. medicao — cada medição de cada contrato
-- ---------------------------------------------------------------------
create table if not exists public.medicao (
  id             bigint generated always as identity primary key,
  contrato       text    not null check (contrato in ('Educação', 'Saúde')),
  numero         integer not null check (numero > 0),
  rotulo         text generated always as ('MED ' || numero::text) stored,  -- igual a os_campo.medicao ("MED 12")
  inicio         date    not null,
  fim            date    not null,
  situacao       text    not null default 'aberta'
                   check (situacao in ('aberta', 'em_conferencia', 'enviada', 'aprovada', 'fechada')),
  valor_oficial  numeric,          -- o que a fiscalização aprovou (planilha oficial)
  obs            text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (contrato, numero),
  check (fim >= inicio)
);
comment on table public.medicao is 'Medições por contrato. Educação: dia 02 ao dia 01; Saúde: mês fechado. Fechada = intocável.';

-- ---------------------------------------------------------------------
-- 4. medicao_os — a O.S. dentro de uma medição (a "linha da Mestra")
-- ---------------------------------------------------------------------
create table if not exists public.medicao_os (
  id                 bigint generated always as identity primary key,
  medicao_id         bigint not null references public.medicao(id) on delete restrict,
  os_id              bigint not null references public.os_campo(id) on delete restrict,
  situacao           text   not null default 'a_lancar'
                       check (situacao in ('a_lancar', 'lancada', 'pulada')),
  fotos_relatorio    text[] not null default '{}',  -- links (de os_campo.foto_urls) escolhidos p/ o relatório
  legenda_relatorio  text,
  resultado_fiscal   text check (resultado_fiscal in ('aprovada', 'glosada', 'reapresentar')),
  motivo_glosa       text,
  lancado_por        text default (auth.jwt() ->> 'email'),
  lancado_em         timestamptz,
  criado_em          timestamptz not null default now(),
  atualizado_em      timestamptz not null default now(),
  unique (medicao_id, os_id)
);
create index if not exists medicao_os_por_os on public.medicao_os (os_id);
comment on table public.medicao_os is 'Cada O.S. de cada medição: lançada/pulada, fotos e legenda do relatório, resultado da fiscalização.';

-- ---------------------------------------------------------------------
-- 5. medicao_lancamento — a memória de cálculo
-- ---------------------------------------------------------------------
create table if not exists public.medicao_lancamento (
  id                bigint generated always as identity primary key,
  medicao_os_id     bigint  not null references public.medicao_os(id) on delete cascade,
  contrato_item_id  bigint  not null references public.contrato_item(id) on delete restrict,
  conta             text    not null,  -- a fita, como o medidor escreveu: "4,20 x 2,80 x 2"
  quantidade        numeric not null check (quantidade > 0),
  preco_unitario    numeric not null check (preco_unitario >= 0),  -- congelado no lançamento (vem do item se vier vazio)
  valor             numeric generated always as (round(quantidade * preco_unitario, 2)) stored,
  local             text,              -- detalhe opcional (sala, fachada, muro…)
  lancado_por       text default (auth.jwt() ->> 'email'),
  lancado_em        timestamptz not null default now()
);
create index if not exists medicao_lancamento_por_os on public.medicao_lancamento (medicao_os_id);
create index if not exists medicao_lancamento_por_item on public.medicao_lancamento (contrato_item_id);
comment on table public.medicao_lancamento is 'Memória de cálculo: um item EMOP + conta + quantidade por linha, preso a uma O.S. de uma medição.';

-- item e medição têm de ser do MESMO contrato; preço vazio = preço do contrato
create or replace function public.fpv_lancamento_confere() returns trigger
language plpgsql
set search_path = public
as $$
declare
  c_medicao text;
  c_item    text;
  p_item    numeric;
begin
  select m.contrato into c_medicao
    from public.medicao_os mo join public.medicao m on m.id = mo.medicao_id
   where mo.id = new.medicao_os_id;
  select contrato, preco_com_bdi into c_item, p_item
    from public.contrato_item where id = new.contrato_item_id;
  if c_medicao is distinct from c_item then
    raise exception 'O item % é do contrato %, mas a medição é do contrato %', new.contrato_item_id, c_item, c_medicao;
  end if;
  if new.preco_unitario is null then
    new.preco_unitario := p_item;
  end if;
  return new;
end;
$$;

drop trigger if exists fpv_lancamento_confere on public.medicao_lancamento;
create trigger fpv_lancamento_confere before insert or update on public.medicao_lancamento
  for each row execute function public.fpv_lancamento_confere();

drop trigger if exists fpv_carimba_contrato_item on public.contrato_item;
create trigger fpv_carimba_contrato_item before update on public.contrato_item
  for each row execute function public.fpv_carimba_atualizado();
drop trigger if exists fpv_carimba_medicao on public.medicao;
create trigger fpv_carimba_medicao before update on public.medicao
  for each row execute function public.fpv_carimba_atualizado();
drop trigger if exists fpv_carimba_medicao_os on public.medicao_os;
create trigger fpv_carimba_medicao_os before update on public.medicao_os
  for each row execute function public.fpv_carimba_atualizado();

-- ---------------------------------------------------------------------
-- 6. RLS — quem vê e quem grava
-- ---------------------------------------------------------------------
-- A medição ainda aceita mudança? (só a FECHADA trava; a aprovada ainda
-- recebe o resultado da fiscalização). Criadas aqui, depois das tabelas:
-- função SQL é conferida na criação e precisa que as tabelas já existam.
create or replace function public.fpv_medicao_aberta(p_medicao_id bigint) returns boolean
language sql stable
set search_path = public
as $$
  select coalesce((select situacao <> 'fechada' from public.medicao where id = p_medicao_id), false);
$$;

create or replace function public.fpv_medicao_os_aberta(p_medicao_os_id bigint) returns boolean
language sql stable
set search_path = public
as $$
  select coalesce((select public.fpv_medicao_aberta(medicao_id) from public.medicao_os where id = p_medicao_os_id), false);
$$;

alter table public.contrato_item      enable row level security;
alter table public.medicao            enable row level security;
alter table public.medicao_os         enable row level security;
alter table public.medicao_lancamento enable row level security;

drop policy if exists "item_leitura"       on public.contrato_item;
drop policy if exists "item_equipe_grava"  on public.contrato_item;
create policy "item_leitura" on public.contrato_item
  for select to authenticated using (true);
create policy "item_equipe_grava" on public.contrato_item
  for all to authenticated using (public.fpv_equipe_medicao()) with check (public.fpv_equipe_medicao());

drop policy if exists "medicao_equipe_le"     on public.medicao;
drop policy if exists "medicao_equipe_cria"   on public.medicao;
drop policy if exists "medicao_equipe_muda"   on public.medicao;
drop policy if exists "medicao_equipe_apaga"  on public.medicao;
create policy "medicao_equipe_le" on public.medicao
  for select to authenticated using (public.fpv_equipe_medicao());
create policy "medicao_equipe_cria" on public.medicao
  for insert to authenticated with check (public.fpv_equipe_medicao());
create policy "medicao_equipe_muda" on public.medicao  -- reabrir medição fechada só pelo service_role
  for update to authenticated using (public.fpv_equipe_medicao() and situacao <> 'fechada')
                              with check (public.fpv_equipe_medicao());
create policy "medicao_equipe_apaga" on public.medicao  -- só medição ainda aberta (e sem O.S., pela chave)
  for delete to authenticated using (public.fpv_equipe_medicao() and situacao = 'aberta');

drop policy if exists "mos_equipe_le"    on public.medicao_os;
drop policy if exists "mos_equipe_grava" on public.medicao_os;
create policy "mos_equipe_le" on public.medicao_os
  for select to authenticated using (public.fpv_equipe_medicao());
create policy "mos_equipe_grava" on public.medicao_os
  for all to authenticated
  using      (public.fpv_equipe_medicao() and public.fpv_medicao_aberta(medicao_id))
  with check (public.fpv_equipe_medicao() and public.fpv_medicao_aberta(medicao_id));

drop policy if exists "lanc_equipe_le"    on public.medicao_lancamento;
drop policy if exists "lanc_equipe_grava" on public.medicao_lancamento;
create policy "lanc_equipe_le" on public.medicao_lancamento
  for select to authenticated using (public.fpv_equipe_medicao());
create policy "lanc_equipe_grava" on public.medicao_lancamento
  for all to authenticated
  using      (public.fpv_equipe_medicao() and public.fpv_medicao_os_aberta(medicao_os_id))
  with check (public.fpv_equipe_medicao() and public.fpv_medicao_os_aberta(medicao_os_id));

-- ---------------------------------------------------------------------
-- 7. Visões prontas (security_invoker: respeitam a RLS de quem consulta)
-- ---------------------------------------------------------------------
-- a memória de cálculo do jeito da aba oficial (ordenar por contrato, rotulo, ordem, escola, os_ref)
create or replace view public.medicao_memoria_calculo with (security_invoker = true) as
select m.contrato, m.numero as medicao_numero, m.rotulo as medicao,
       ci.ordem, ci.item, ci.codigo_emop, ci.descricao, ci.unid,
       o.unidade as escola,
       coalesce(o.numero::text, o.fict_ref, 'F-' || o.numero_fict::text) as os_ref,
       l.conta, l.quantidade, l.preco_unitario, l.valor, l.local,
       mo.situacao, mo.resultado_fiscal, l.lancado_por, l.lancado_em
  from public.medicao_lancamento l
  join public.medicao_os    mo on mo.id = l.medicao_os_id
  join public.medicao       m  on m.id  = mo.medicao_id
  join public.contrato_item ci on ci.id = l.contrato_item_id
  join public.os_campo      o  on o.id  = mo.os_id;

-- resumo por item (a aba de proposta)
create or replace view public.medicao_resumo_item with (security_invoker = true) as
select m.contrato, m.numero as medicao_numero, m.rotulo as medicao,
       ci.ordem, ci.item, ci.codigo_emop, ci.descricao, ci.unid, ci.preco_com_bdi,
       sum(l.quantidade) as quantidade, sum(l.valor) as valor, count(*) as linhas
  from public.medicao_lancamento l
  join public.medicao_os    mo on mo.id = l.medicao_os_id
  join public.medicao       m  on m.id  = mo.medicao_id
  join public.contrato_item ci on ci.id = l.contrato_item_id
 where mo.situacao = 'lancada'
 group by m.contrato, m.numero, m.rotulo, ci.ordem, ci.item, ci.codigo_emop, ci.descricao, ci.unid, ci.preco_com_bdi;

-- saldo de cada item: contratado − medido antes do sistema − lançado depois (radar, não bloqueia)
create or replace view public.contrato_item_saldo with (security_invoker = true) as
with depois as (   -- só o lançado em medições DEPOIS do marco (o antes já está em qtd_medida_anterior)
  select l.contrato_item_id, sum(l.quantidade) as qtd
    from public.medicao_lancamento l
    join public.medicao_os    mo on mo.id = l.medicao_os_id and mo.situacao = 'lancada'
    join public.medicao       m  on m.id  = mo.medicao_id
    join public.contrato_item c  on c.id  = l.contrato_item_id
   where m.numero > coalesce(c.medida_anterior_ate, 0)
   group by l.contrato_item_id
)
select ci.id, ci.contrato, ci.ordem, ci.item, ci.codigo_emop, ci.descricao, ci.unid,
       ci.qtd_contratada, ci.qtd_medida_anterior, ci.medida_anterior_ate,
       coalesce(d.qtd, 0) as qtd_lancada_depois,
       ci.qtd_contratada - ci.qtd_medida_anterior - coalesce(d.qtd, 0) as saldo,
       ci.preco_com_bdi
  from public.contrato_item ci
  left join depois d on d.contrato_item_id = ci.id;

-- trava anti-medição dupla (aviso): O.S. aprovada pela fiscalização em mais de uma medição
create or replace view public.medicao_os_cobrada_2x with (security_invoker = true) as
select mo.os_id,
       coalesce(o.numero::text, o.fict_ref, 'F-' || o.numero_fict::text) as os_ref,
       o.unidade as escola,
       array_agg(m.rotulo order by m.numero) as medicoes
  from public.medicao_os mo
  join public.medicao  m on m.id = mo.medicao_id
  join public.os_campo o on o.id = mo.os_id
 where mo.resultado_fiscal = 'aprovada'
 group by mo.os_id, o.numero, o.fict_ref, o.numero_fict, o.unidade
having count(*) > 1;

-- ---------------------------------------------------------------------
-- 8. GRANTs (regra de 30/10/2026) — anon fica de fora de propósito
-- ---------------------------------------------------------------------
revoke all on public.contrato_item, public.medicao, public.medicao_os, public.medicao_lancamento from anon;
revoke all on public.medicao_memoria_calculo, public.medicao_resumo_item, public.contrato_item_saldo, public.medicao_os_cobrada_2x from anon;
grant select, insert, update, delete on public.contrato_item, public.medicao, public.medicao_os, public.medicao_lancamento to authenticated;
grant select on public.medicao_memoria_calculo, public.medicao_resumo_item, public.contrato_item_saldo, public.medicao_os_cobrada_2x to authenticated;
grant all on public.contrato_item, public.medicao, public.medicao_os, public.medicao_lancamento to service_role;
grant select on public.medicao_memoria_calculo, public.medicao_resumo_item, public.contrato_item_saldo, public.medicao_os_cobrada_2x to service_role;
grant execute on function public.fpv_equipe_medicao(), public.fpv_medicao_aberta(bigint), public.fpv_medicao_os_aberta(bigint) to authenticated, service_role;

commit;
