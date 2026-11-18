#!/usr/bin/env python3
"""Leva para o banco as listas de O.S. APROVADAS das MED 8, 9 e 10 da Educação (as listas
"O.S LANÇADAS nª MEDIÇÃO" do Edmar, em /root/fpv-mestra/aprovadas_*.csv: med;os;escola).

Para a trava anti-medição dupla do Painel do Medidor funcionar igual à da Planilha Mestra:
O.S. aprovada numa medição não entra de novo noutra. Mesma regra do gerar_mestra.py:
  - casa pela referência normalizada (chave_os: "L100 - EMERGÊNCIAL" = "L100", "F-98" = "F98");
  - fictícia aprovada que virou nº oficial (par_sugerido) passa a aprovação para o oficial;
  - nº que aparece 2x no sistema (1218, 1673…): as duas linhas ficam marcadas, como na Mestra.
Cria as medições 8, 9 e 10 (situação "aprovada") e uma linha em medicao_os por O.S. aprovada
(situação "lancada", resultado_fiscal "aprovada", sem lançamento de item — o valor de cada
medição antiga continua na planilha oficial).

Roda NA VPS, só lendo (banco em read-only + CSVs), e escreve o SQL no stdout:
  ssh arka "python3 -" < gera_aprovadas_historicas.py > sql/0012c_aprovadas_historicas.sql
"""
import sys, re, csv, json, glob, subprocess
from collections import defaultdict
from datetime import date

PASTA = "/root/fpv-mestra"
PERIODO = {8: ("2026-07-02", "2026-08-01"), 9: ("2026-08-02", "2026-09-01"), 10: ("2026-09-02", "2026-10-01")}


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", "supabase-db", "psql", "-U", "postgres", "-d", "postgres", "-At"],
                       input=f"set default_transaction_read_only = on;\nselect coalesce(json_agg(t),'[]') from ({q}) t;",
                       capture_output=True, text=True, check=True)
    return json.loads(" ".join(l for l in r.stdout.splitlines() if l.strip() != "SET"))


def chave_os(s):
    s = re.sub(r"(?i)emerg[eê]ncial", "", s or "")
    return re.sub(r"[^A-Z0-9]", "", s.upper())


def ref(o):
    if o.get("numero") is not None:
        return str(o["numero"])
    return o.get("fict_ref") or (f"F-{o['numero_fict']}" if o.get("numero_fict") else "S/Nº")


OS = sql("select id, numero, numero_fict, fict_ref, par_sugerido from os_campo where coalesce(excluida,false) = false")
por_chave = defaultdict(list)
for o in OS:
    por_chave[chave_os(ref(o))].append(o)
    if o.get("fict_ref"):
        por_chave[chave_os(o["fict_ref"])].append(o)

aprov = defaultdict(set)          # chave -> {8, 9, 10}
linhas_csv = 0
for arq in glob.glob(f"{PASTA}/aprovadas_*.csv"):
    with open(arq, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f, delimiter=";"):
            m = re.search(r"(\d+)", r.get("med") or "")
            if (r.get("os") or "").strip() and m and int(m.group(1)) in PERIODO:
                aprov[chave_os(r["os"])].add(int(m.group(1)))
                linhas_csv += 1
# fictícia aprovada que virou oficial: a aprovação passa para o nº oficial (regra da Mestra)
for o in OS:
    if o.get("par_sugerido") and chave_os(ref(o)) in aprov:
        aprov[chave_os(str(o["par_sugerido"]))] |= aprov[chave_os(ref(o))]

pares = set()                     # (medicao, os_id)
sem_par = []
for k, meds in aprov.items():
    alvo = {o["id"]: o for o in por_chave.get(k, [])}
    if not alvo:
        sem_par.append(k)
        continue
    for oid in alvo:
        for m in meds:
            pares.add((m, oid))

out = [f"""-- =====================================================================
-- 0012c · O.S. JÁ APROVADAS nas MED 8, 9 e 10 da Educação (listas do Edmar)
-- Gerado em {date.today():%d/%m/%Y} por scripts/gera_aprovadas_historicas.py
-- {linhas_csv} linhas das listas -> {len(pares)} pares (medição, O.S.) no banco;
-- {len(sem_par)} referência(s) das listas não existem no sistema: {', '.join(sorted(sem_par)) or '-'}
-- Para desfazer: delete from medicao_os where medicao_id in (select id from medicao
--   where contrato='Educação' and numero in (8,9,10)); delete from medicao where
--   contrato='Educação' and numero in (8,9,10);
-- =====================================================================
begin;
insert into public.medicao (contrato, numero, inicio, fim, situacao, obs) values"""]
out.append(",\n".join(f"  ('Educação', {n}, '{a}', '{b}', 'aprovada', 'histórico: lista de O.S. aprovadas do Edmar (sem valor no banco)')"
                      for n, (a, b) in sorted(PERIODO.items())))
out.append("on conflict (contrato, numero) do nothing;\n")
for n in sorted(PERIODO):
    ids = sorted(oid for m, oid in pares if m == n)
    if not ids:
        continue
    out.append(f"-- MED {n}: {len(ids)} O.S.")
    out.append("insert into public.medicao_os (medicao_id, os_id, situacao, resultado_fiscal, lancado_por, lancado_em)")
    out.append(f"select m.id, o.os_id, 'lancada', 'aprovada', 'lista do Edmar (histórico)', null")
    out.append(f"  from public.medicao m, unnest(array[{','.join(map(str, ids))}]::bigint[]) as o(os_id)")
    out.append(f" where m.contrato = 'Educação' and m.numero = {n}")
    out.append("on conflict (medicao_id, os_id) do nothing;\n")
out.append("commit;\n")
sys.stdout.write("\n".join(out))
