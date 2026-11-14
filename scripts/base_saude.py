#!/usr/bin/env python3
"""Base de preços + histórico de medição (jurisprudência) da SAÚDE FP.096 — contrato 005/2026.

Lê as planilhas oficiais de medição (MED 01..05, Drive G:) recebidas como um TAR no stdin
(membros medNN.xlsm), sem gravar nada em disco, e devolve JSON no stdout:

  modo base  -> itens do contrato (código EMOP, descrição, unid., qtd contratada, preço c/ BDI,
                seção, quanto já foi medido nas MED lidas e o saldo calculado)
  modo jur   -> por código EMOP: quantas contas de memória foram aceitas, em quantas unidades,
                em quais medições e 2 exemplos (unidade | local | conta)
  modo check -> soma de cada medição (qtd no período x preço c/ BDI) para conferir com o RESUMO

As planilhas originais são só lidas (regra do projeto). O saldo NÃO usa a coluna "acumulado
anterior" (na MED 05 ela esquece a MED 04): é contratado − soma do "no período" de cada MED.

  tar cf - med01.xlsm ... med05.xlsm | ssh arka "python3 -c \"import base64;exec(base64.b64decode('<script>'))\" base"
"""
import sys, io, re, json, tarfile
from collections import defaultdict
import openpyxl

MODO = sys.argv[1] if len(sys.argv) > 1 else "base"
COD = re.compile(r"^\d{2}\.\d{3}\.\d{4}(-[A-Z])?$|^\d{5}$")


def txt(v):
    return "" if v is None else str(v).strip()


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def cod_de(v):
    s = txt(v)
    if isinstance(v, float) and v.is_integer():
        s = str(int(v))
    return s if COD.match(s) else ""


arquivos = {}
with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tf:
    for m in tf:
        if m.isfile():
            n = int(re.search(r"(\d+)", m.name.split("/")[-1]).group(1))
            arquivos[n] = tf.extractfile(m).read()

base, medido, check = {}, defaultdict(float), {}
jur = defaultdict(lambda: {"n": 0, "unids": set(), "meds": set(), "ex": [], "unid": ""})

for n in sorted(arquivos):
    wb = openpyxl.load_workbook(io.BytesIO(arquivos[n]), data_only=True, read_only=True)
    med = f"MED{n:02d}"
    # ---- planilha de medição: acha as colunas pelo cabeçalho
    ws = next(w for w in wb.worksheets if w.title.upper().startswith("MEDI"))
    rows = list(ws.iter_rows(values_only=True))
    # (as MED 01-04 não têm a coluna "ITEM REF. A ARP": tudo anda 1 coluna para a esquerda)
    c_per, c_bdi, c_cod = 10, 8, 3
    for r in rows[:22]:
        for j, v in enumerate(r):
            t = txt(v).upper()
            if t == "NO PERÍODO":
                c_per = j
            if t == "COM BDI":
                c_bdi = j
            if t == "CÓDIGO EMOP":
                c_cod = j
    off = c_cod - 3
    secao, total = "", 0.0
    for r in rows:
        if len(r) < 9 + off:
            continue
        cod = cod_de(r[3 + off])
        if not cod:
            if txt(r[3 + off]) and re.match(r"^\d{2}\s*-\s*\S", txt(r[3 + off])):
                secao = re.sub(r"^\d{2}\s*-\s*", "", txt(r[3 + off]))
            continue
        preco = num(r[c_bdi])
        if preco is None or not txt(r[5 + off]):
            continue
        q = num(r[c_per]) if len(r) > c_per else None
        if q:
            medido[cod] += q
            total += q * preco
        base[cod] = {"item": txt(r[2 + off]), "ref": txt(r[1]) if off == 0 else "", "cod": cod,
                     "desc": re.sub(r"\s+", " ", txt(r[4 + off])), "unid": txt(r[5 + off]), "qc": num(r[6 + off]),
                     "preco": round(preco, 2), "secao": secao}
    check[med] = {"total": round(total, 2), "col_periodo": c_per, "col_bdi": c_bdi, "deslocamento": off, "aba": ws.title}
    # ---- memória de cálculo
    wm = next((w for w in wb.worksheets if w.title.upper().startswith("MEM")), None)
    if wm is None:
        continue
    atual, unidade, local, eq = "", "", "", 11 + off
    for r in wm.iter_rows(values_only=True):
        if len(r) < 13 + off:
            continue
        cod = cod_de(r[3 + off])
        if cod and len(r) > 20 + off and txt(r[20 + off]):
            atual, unidade, local, eq = cod, "", "", 11 + off
            jur[cod]["unid"] = txt(r[20 + off])
            continue
        if not atual:
            continue
        if len(r) > 15 + off and "TOTAL MEDIDO" in txt(r[15 + off]).upper():
            continue
        # linha de títulos do bloco (COMPRIMENTO X ALTURA X LADOS = ÁREA): o "=" diz onde está o total
        if any(txt(v) == "=" for v in r):
            eq = next(j for j, v in enumerate(r) if txt(v) == "=")
            continue
        if txt(r[3 + off]) and not num(r[3 + off]):
            unidade, local = txt(r[3 + off]), ""
        if txt(r[4 + off]) and txt(r[4 + off]).upper() != "LOCAL":
            local = txt(r[4 + off])
        fat = [num(r[k]) for k in range(5 + off, eq) if k < len(r)]
        tot = num(r[eq + 1]) if eq + 1 < len(r) else None
        if not tot or all(f is None for f in fat):
            continue
        conta = " x ".join(f"{f:g}" for f in fat if f is not None) + f" = {tot:g}"
        j = jur[atual]
        j["n"] += 1
        j["meds"].add(med)
        if unidade:
            j["unids"].add(unidade.upper())
        ex = f"{unidade} | {local} | {conta}"
        if len(j["ex"]) < 2 and ex not in j["ex"]:
            j["ex"].append(ex)

if MODO == "check":
    json.dump(check, sys.stdout, ensure_ascii=False)
elif MODO == "jur":
    saida = [{"cod": c, "unid": j["unid"], "n": j["n"], "nos": len(j["unids"]), "nesc": len(j["unids"]),
              "meds": ",".join(sorted(j["meds"])), "ex1": (j["ex"] + ["", ""])[0], "ex2": (j["ex"] + ["", ""])[1]}
             for c, j in jur.items() if j["n"]]
    saida.sort(key=lambda x: -x["n"])
    json.dump(saida, sys.stdout, ensure_ascii=False)
else:
    ate = max(arquivos) if arquivos else 0
    saida = []
    for c, b in base.items():
        b = dict(b)
        b["medido"] = round(medido.get(c, 0.0), 4)
        b["saldo"] = round(b["qc"] - b["medido"], 4) if b["qc"] is not None else None
        b["saldo_ate"] = f"MED {ate:02d}"
        saida.append(b)
    json.dump(saida, sys.stdout, ensure_ascii=False)
