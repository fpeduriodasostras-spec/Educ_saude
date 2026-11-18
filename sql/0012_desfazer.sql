-- =====================================================================
-- DESFAZER a 0012 (medição no banco) — só se precisar voltar atrás.
-- ⚠️ APAGA os lançamentos de medição que tiverem sido feitos nessas tabelas.
-- Não toca em os_campo nem em nada que existia antes da 0012.
-- =====================================================================
begin;
drop view if exists public.medicao_os_cobrada_2x, public.contrato_item_saldo,
                    public.medicao_resumo_item, public.medicao_memoria_calculo;
drop table if exists public.medicao_lancamento, public.medicao_os, public.medicao, public.contrato_item;
drop function if exists public.fpv_lancamento_confere(), public.fpv_medicao_os_aberta(bigint),
                        public.fpv_medicao_aberta(bigint), public.fpv_equipe_medicao(),
                        public.fpv_carimba_atualizado();
commit;
