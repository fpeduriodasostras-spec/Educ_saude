#!/usr/bin/env python3
"""Gera sql/0012b_medicao_dados.sql: os itens dos dois contratos e as medições abertas.

Lê um TAR no stdin (não grava nada em disco) com:
  BASE-CONTRATO-064-2025.csv          Educação: 288 itens conferidos ao centavo (R$ 11.698.291,07)
  SALDO-POR-ITEM-OFICIAL-MED09.csv    Educação: acumulado OFICIAL por item após a MED 09
  base_saude.json                     Saúde: 319 itens + medido nas MED 01-05 (somas batem com as oficiais)
e escreve o SQL no stdout. Tudo com "on conflict do nothing": rodar de novo não duplica.

  tar cf - BASE-CONTRATO-064-2025.csv SALDO-POR-ITEM-OFICIAL-MED09.csv base_saude.json \
    | ssh arka "python3 -c \"import base64;exec(base64.b64decode('<este script>'))\"" > sql/0012b_medicao_dados.sql
"""
import sys, io, csv, json, tarfile
from datetime import datetime
from zoneinfo import ZoneInfo

arq = {}
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tf:
    for m in tf:
        if m.isfile():
            arq[m.name.split("/")[-1]] = tf.extractfile(m).read()


def q(v):
    """valor SQL: texto com aspas dobradas, número cru, vazio = null"""
    if v is None or (isinstance(v, str) and not v.strip()):
        return "null"
    if isinstance(v, (int, float)):
        return repr(v) if isinstance(v, float) else str(v)
    return "'" + str(v).strip().replace("'", "''") + "'"


def num(s):
    s = (s or "").strip()
    if not s:
        return None
    v = float(s.replace(",", "."))
    return int(v) if v.is_integer() else v


def linhas_csv(nome):
    return list(csv.DictReader(io.StringIO(arq[nome].decode("utf-8-sig")), delimiter=";"))


saida = []
agora = datetime.now(ZoneInfo("America/Sao_Paulo")).strftime("%d/%m/%Y %H:%M")
saida.append(f"""-- =====================================================================
-- 0012b · DADOS INICIAIS DA MEDIÇÃO NO BANCO (rodar DEPOIS da 0012)
-- Gerado por scripts/gera_seed_medicao.py em {agora} · ⚠️ NÃO APLICADO
-- · contrato_item Educação: BASE-CONTRATO-064-2025.csv (288 itens, conferida ao
--   centavo) + acumulado OFICIAL até a MED 09 (SALDO-POR-ITEM-OFICIAL-MED09.csv).
--   As MED 10 e 11 ainda NÃO estão somadas: quando a oficial delas chegar, atualizar
--   qtd_medida_anterior/medida_anterior_ate (ou lançar as duas pelo painel).
-- · contrato_item Saúde: planilhas oficiais MED 01-05 (somas batem com as oficiais);
--   medido até a MED 05 (as MED 06+ não estão no Drive G:).
-- · medicao: só as duas medições abertas hoje. Histórico não entra (sem número
--   oficial confirmado de cada uma — regra "só dados do banco").
-- Idempotente: on conflict do nothing.
-- =====================================================================
begin;
""")

# ---- Educação
saldo = {r["codigo_emop"].strip(): r for r in linhas_csv("SALDO-POR-ITEM-OFICIAL-MED09.csv")}
cols = "(contrato, item, item_arp, codigo_emop, descricao, unid, secao, ordem, qtd_contratada, preco_sem_bdi, preco_com_bdi, qtd_medida_anterior, medida_anterior_ate)"
edu = linhas_csv("BASE-CONTRATO-064-2025.csv")
vals = []
for i, r in enumerate(edu, 1):
    s = saldo.get(r["codigo_emop"].strip())
    ant = num(s["acum_oficial_med09"]) if s else 0
    vals.append("  (" + ", ".join([q("Educação"), q(r["item"]), "null", q(r["codigo_emop"]), q(r["descricao"]), q(r["unid"]),
                                   q(r.get("secao")), str(i), q(num(r["qtd_contratada"])), q(num(r["preco_sem_bdi"])),
                                   q(num(r["preco_com_bdi"])), q(ant or 0), "9"]) + ")")
saida.append(f"-- Educação FP.094 · contrato 064/2025 · {len(vals)} itens ({sum(1 for r in edu if saldo.get(r['codigo_emop'].strip()))} com acumulado oficial da MED 09)")
saida.append(f"insert into public.contrato_item {cols} values\n" + ",\n".join(vals) + "\non conflict (contrato, codigo_emop) do nothing;\n")

# ---- Saúde
sau = json.loads(arq["base_saude.json"].decode("utf-8"))
vals = []
for i, b in enumerate(sau, 1):
    vals.append("  (" + ", ".join([q("Saúde"), q(b.get("item")), q(b.get("ref")), q(b["cod"]), q(b["desc"]), q(b["unid"]),
                                   q(b.get("secao")), str(i), q(b.get("qc")), "null", q(b["preco"]),
                                   q(b.get("medido") or 0), "5"]) + ")")
saida.append(f"-- Saúde FP.096 · contrato 005/2026 · {len(vals)} itens (medido até a MED 05)")
saida.append(f"insert into public.contrato_item {cols} values\n" + ",\n".join(vals) + "\non conflict (contrato, codigo_emop) do nothing;\n")

# ---- medições abertas hoje
saida.append("""-- medições abertas (Educação: dia 02 ao 01 · Saúde: mês fechado)
insert into public.medicao (contrato, numero, inicio, fim, situacao) values
  ('Educação', 12, '2026-11-02', '2026-12-01', 'aberta'),
  ('Saúde',     9, '2026-11-01', '2026-11-30', 'aberta')
on conflict (contrato, numero) do nothing;

commit;
""")
sys.stdout.write("\n".join(saida))
