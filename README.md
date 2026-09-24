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
