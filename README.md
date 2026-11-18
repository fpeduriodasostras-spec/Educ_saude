# Medição Automática — F.P. Vieira Engenharia

Motor de apoio à medição mensal dos contratos de manutenção (Educação FP.094,
Saúde FP.096 e próximos). Nasce em 24/09/2026, desenvolvido pelo Leony com o
Claude Code, em parceria com o app de Medições (artifact do Claude) criado pelo
colaborador orientado pelo Renan.

## O objetivo

Todo mês, a partir do que a equipe já lançou (O.S., fotos, materiais), gerar
**automaticamente o rascunho da memória de cálculo** — escola, nº da O.S. e
quantidades na unidade da EMOP — para o conferente (Edmar) só dar o check ✓
ou editar. A regra de ouro: **o robô propõe, a pessoa aprova.**

## O que já está aqui

| Arquivo | O que é |
|---|---|
| `data/BASE-CONTRATO-064-2025.csv` | Os 288 itens EMOP do contrato da Educação com preço (sem/com BDI) e quantidade contratada — conferido ao centavo (R$ 11.698.291,07) |
| `data/BASE-COLAR-PRECOS.txt` | A mesma base em 2 colunas (TAB), pronta para colar na tela "Colar preços" do app de Medições |
| `data/SALDO-POR-ITEM-OFICIAL-MED09.csv` | Radar de saldo por item após a MED 09 (acumulado OFICIAL — a série mensal sofre glosa retroativa, nunca somar os meses) |
| `data/SERIE-MENSAL.csv` | As 9 medições conferidas contra os RESUMOs oficiais |
| `data/HISTORICO-OS-MEDIDAS.csv` | (gerado pela mineração) Cada linha de memória de cálculo já aceita: medição, item EMOP, escola, O.S., dimensões e total |
| `data/JURISPRUDENCIA-EMOP.csv` | (gerado pela mineração) Como cada tipo de serviço costuma ser medido e aceito |

## Painel "Motor de Medição FPV" (front/)

`front/motor.html` é o painel de conferência (publicado como artifact do Claude). Desde 10/11/2026
ele lê a medição do **banco central da VPS** (tabela `os_campo`, só leitura) por meio de
`scripts/exporta_painel.py`, que roda pelo ssh sem gravar nada no servidor:

    ssh arka "python3 - MED 12 2026-11-02 2026-12-01 os"    < scripts/exporta_painel.py > front/data/os_med12.json
    ssh arka "python3 - MED 12 2026-11-02 2026-12-01 fotos" < scripts/exporta_painel.py > fotos.tsv
    # fotos.tsv -> front/data/fotos/<id>.json (uma linha por O.S.: id TAB miniaturas)

Para virar de medição, troque `ARQ_OS` no topo do script do painel (ou publique um
`data/atual.json` = `{"arquivo": "data/os_....json"}`, que manda nele). As decisões ficam gravadas
por medição (`decisoes/MED12-N-2950`). As miniaturas (`front/data/fotos/`) não vão para o git.

**Saúde (FP.096, contrato 005/2026) — desde 11/11/2026.** O mesmo `motor.html` serve aos dois
contratos: o arquivo da medição traz na `meta` qual base e histórico usar e as regras (Saúde sem nº
oficial de O.S., histórico contado por unidade, material entra na sugestão). Peças da Saúde:

    # base de preços + histórico, lidos das planilhas oficiais MED 01-05 (Drive G:), só leitura
    tar cf - med01.xlsm ... med05.xlsm | ssh arka "python3 -c \"import base64,sys;sys.argv=['x','base'];exec(base64.b64decode('<scripts/base_saude.py em base64>'))\"" > front/data/base_saude.json
    #   modos: base | jur (-> front/data/jur_saude.json) | check (soma de cada MED; bateu com o RESUMO)
    # O.S. do mês (Saúde mede o mês fechado: MED 09 = 01/11 a 30/11)
    ssh arka "python3 - MED 09 2026-11-01 2026-11-30 os saude" < scripts/exporta_painel.py > front/data/os_saude_med09.json

O saldo da base da Saúde é contratado − soma do "no período" das MED lidas (a coluna "acumulado
anterior" da MED 05 esquece a MED 04). As MED 06 em diante não estão no Drive G:.

## Painel "Planilha Mestra FPV" (front/mestra.html) — modelo de 11/11/2026

A Planilha Mestra do mês em forma de painel: as mesmas 10 abas do Excel (Conferência, O.S 2026,
MED n em andamento / pronta / completar antes / sem nº, Fotos, Aguardando nº, Vinculadas,
Reapresentar MED 9-10), com busca, filtro de status, ordenação, ficha da O.S. com fotos e
"Baixar esta aba (Excel)". Os números saem do PRÓPRIO `gerar_mestra.py` da VPS: o
`scripts/exporta_mestra.py` roda o gerador trocando só o `wb.save(...)` por JSON (nada gravado no
servidor, banco em read-only), então o painel bate com o Excel que vai para a fiscalização:

    ssh arka "python3 - MED 12 2026-11-02 2026-12-01" < scripts/exporta_mestra.py > front/data/mestra_med12.json

As miniaturas das fotos são as mesmas do Motor (`front/data/fotos/<id>.json`, modo `fotos` do
`exporta_painel.py`). Para virar de medição, troque `ARQ` no topo do script do painel.

## Painel do Medidor (front/medidor.html) — v1 de 11/11/2026, Educação

Um painel só para o medidor (Edmar), juntando a Planilha Mestra, o motor, a memória de cálculo e o
relatório fotográfico. Abas: Conferência · **Medição** (lista de trabalho: O.S. da Mestra em andamento
+ sem nº, nas cores da Mestra do Renan — verde = lançada, amarelo = falta algo, azul = sugestão do
motor, amarelo-claro = código lançado) · **Memória de cálculo** (das lançadas, no desenho da aba
MEMÓRIA CÁLCULO oficial; baixa em Excel) · **Relatório fotográfico** (PDF no modelo oficial: cabeçalho
da Secretaria, título por O.S., fotos VGA de 2 em 2) · O.S 2026 · Aguardando nº · Vinculadas ·
Reapresentar · Estilos. A ficha da O.S. mostra tudo, deixa escolher as fotos do relatório, lançar
código + conta e ir para a próxima. Lançamentos ficam no banco do próprio artifact (`decisoes/MED12-…`).

    ssh arka "python3 - MED 12 2026-11-02 2026-12-01" < scripts/exporta_mestra.py > front/data/mestra_med12.json
    ssh arka "python3 - MED 12 2026-11-02 2026-12-01 fotos edu 640" < scripts/exporta_painel.py > fotos.tsv
    # fotos.tsv -> front/data/fotos_vga/<id>.json (640 px = "VGA", o tamanho do relatório oficial)

## A medição no banco (sql/0012) — APLICADA no Supabase da VPS em 18/11/2026 14:56

`sql/0012_medicao.sql` cria 4 tabelas novas no Supabase da VPS, sem mexer em nada que existe:
`contrato_item` (itens dos contratos), `medicao` (cada medição e situação), `medicao_os` (a O.S.
dentro da medição: lançada/pulada, fotos e legenda do relatório, resultado da fiscalização) e
`medicao_lancamento` (a memória de cálculo). Mais 4 visões prontas (memória de cálculo, resumo por
item, saldo por item, O.S. aprovada em duas medições). Permissões: anon sem acesso; qualquer login lê
os itens do contrato; medição só a equipe (`fpv_equipe_medicao()`); medição fechada não muda.
`sql/0012b_medicao_dados.sql` (gerado por `scripts/gera_seed_medicao.py`) carrega 288 itens da
Educação (acumulado oficial até a MED 09) + 319 da Saúde (medido até a MED 05) e as duas medições abertas.

Testado em 14/11 num Postgres DESCARTÁVEL (imagem supabase/postgres 15.8, sem rede, apagado no fim):
rodou 2× sem erro e sem duplicar; casos em `sql/teste/` (equipe lança; item de outro contrato dá erro;
quem não é da equipe e anon não veem; medição fechada trava; aviso de O.S. aprovada 2×).
Aplicada em 18/11/2026 às 14:56 (lock_timeout 3 s, < 1 s de execução; os_campo intacta). Conferido:
288 + 319 itens, MED 12 Educação e MED 9 Saúde abertas, RLS e GRANTs certos, API recusa anon (401).
Para voltar atrás: `sql/0012_desfazer.sql`. Falta copiar para as migrations do app (Educacao_saude_ON).

## Regras herdadas do projeto (não negociar sem o Renan)

- Planilhas originais do contrato são **somente leitura**; todo produto nasce em arquivo novo.
- Nunca editar arquivo de projeto por comando do PowerShell (BOM/acentos); gravar com `UTF8Encoding($false)`.
- Datas em planilha: número de série + formato `dd"/"mm"/"yyyy`, e conferir uma data contra a fonte antes de entregar.
- O número da O.S. não é único no banco (1218 e 1673 duplicadas) — cruzar por par escola+O.S.
- A mesma escola tem até 122 grafias — normalizar antes de agrupar.

## Fontes

- Planilhas oficiais MED 01–09 (Drive H:, `ENGENHARIA/Medições/00 - MEDIÇÃO FP-VIEIRA`).
- Mestra e exportações do sistema (Drive H:, `_AUDITORIA E FERRAMENTAS FPV`).
- App de campo FPV (Supabase) e app de Medições — integração pendente das chaves.
