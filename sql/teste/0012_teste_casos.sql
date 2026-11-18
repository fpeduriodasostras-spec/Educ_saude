\set ON_ERROR_STOP 0
\pset footer off
\echo '=== contagens depois de rodar 0012 + 0012b DUAS vezes'
select contrato, count(*) itens, count(*) filter (where qtd_medida_anterior > 0) as com_medido_antes from public.contrato_item group by 1 order by 1;
select contrato, rotulo, inicio, fim, situacao from public.medicao order by 1;

\echo '=== 1) Edmar (equipe) lança a O.S. 1681 na MED 12: deve funcionar'
begin;
set local role authenticated;
set local request.jwt.claims = '{"email":"edmar@fpv.app","role":"authenticated"}';
insert into public.medicao_os (medicao_id, os_id, situacao, fotos_relatorio, legenda_relatorio, lancado_em)
  select id, 1682, 'lancada', array['https://x/1.jpg'], 'Instalação de ar condicionado', now() from public.medicao where contrato='Educação' and numero=12;
insert into public.medicao_lancamento (medicao_os_id, contrato_item_id, conta, quantidade, preco_unitario)
  select mo.id, ci.id, '3', 3, null from public.medicao_os mo, public.contrato_item ci
   where mo.os_id=1682 and ci.contrato='Educação' and ci.codigo_emop='15.005.0215-A';
insert into public.medicao_lancamento (medicao_os_id, contrato_item_id, conta, quantidade)
  select mo.id, ci.id, '4,2 x 2,8 x 2', 23.52 from public.medicao_os mo, public.contrato_item ci
   where mo.os_id=1682 and ci.contrato='Educação' and ci.codigo_emop='17.018.0031-A';
select medicao, item, codigo_emop, escola, os_ref, conta, quantidade, preco_unitario, valor, lancado_por from public.medicao_memoria_calculo order by ordem;
select medicao, codigo_emop, quantidade, valor from public.medicao_resumo_item order by ordem;
select codigo_emop, qtd_contratada, qtd_medida_anterior, qtd_lancada_depois, saldo from public.contrato_item_saldo where codigo_emop in ('15.005.0215-A','17.018.0031-A') and contrato='Educação';
commit;

\echo '=== 2) Item da SAÚDE numa medição da EDUCAÇÃO: deve dar ERRO'
begin;
set local role authenticated;
set local request.jwt.claims = '{"email":"edmar@fpv.app","role":"authenticated"}';
insert into public.medicao_lancamento (medicao_os_id, contrato_item_id, conta, quantidade)
  select mo.id, ci.id, '1', 1 from public.medicao_os mo, public.contrato_item ci
   where mo.os_id=1682 and ci.contrato='Saúde' limit 1;
rollback;

\echo '=== 3) Marcio (fora da equipe de medição): vê os itens do contrato, NÃO vê nem grava medição'
begin;
set local role authenticated;
set local request.jwt.claims = '{"email":"marcio@fpv.app","role":"authenticated"}';
select count(*) as itens_que_marcio_ve from public.contrato_item;
select count(*) as medicoes_que_marcio_ve from public.medicao;
select count(*) as linhas_memoria_que_marcio_ve from public.medicao_memoria_calculo;
insert into public.medicao (contrato, numero, inicio, fim) values ('Educação', 99, '2027-01-02', '2027-02-01');
rollback;

\echo '=== 4) anon (sem login): NÃO acessa nada'
begin;
set local role anon;
select count(*) from public.contrato_item;
rollback;
begin;
set local role anon;
select count(*) from public.medicao;
rollback;

\echo '=== 5) Medição FECHADA fica intocável'
update public.medicao set situacao='fechada' where contrato='Educação' and numero=12;
begin;
set local role authenticated;
set local request.jwt.claims = '{"email":"edmar@fpv.app","role":"authenticated"}';
insert into public.medicao_os (medicao_id, os_id) select id, 1694 from public.medicao where contrato='Educação' and numero=12;
rollback;
begin;
set local role authenticated;
set local request.jwt.claims = '{"email":"edmar@fpv.app","role":"authenticated"}';
delete from public.medicao_lancamento;
select count(*) as lancamentos_continuam from public.medicao_lancamento;
update public.medicao set situacao='aberta' where numero=12;
select situacao as continua from public.medicao where numero=12 and contrato='Educação';
rollback;

\echo '=== 6) Trava anti-medição dupla: mesma O.S. aprovada em duas medições aparece no aviso'
insert into public.medicao (contrato, numero, inicio, fim, situacao) values ('Educação', 11, '2026-10-02', '2026-11-01', 'aprovada') on conflict do nothing;
insert into public.medicao_os (medicao_id, os_id, situacao, resultado_fiscal) select id, 1682, 'lancada', 'aprovada' from public.medicao where contrato='Educação' and numero=11;
update public.medicao_os set resultado_fiscal='aprovada' where os_id=1682;
select os_ref, escola, medicoes from public.medicao_os_cobrada_2x;
