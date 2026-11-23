#!/usr/bin/env python3
"""ESTILOS APRENDIDOS do histórico: para cada TIPO de serviço, quais itens EMOP a fiscalização
aceitou nas MED 01-09 da Educação. Junta duas coisas que já temos:
  - data/HISTORICO-OS-MEDIDAS.csv (stdin): 8.668 linhas de memória de cálculo ACEITA
    (medicao;item;codigo_emop;unid;escola;os_ref;expressao;quantidade)
  - os_campo (banco da VPS, só leitura): o serviço de cada O.S. -> tipo (mesma tabela da Mestra)
Só entram linhas cuja coluna O.S. traz um número (ou fictícia L/M/F…) que exista no sistema;
a coluna às vezes traz o LOCAL ("PAREDES EXTERNAS"), e essas ficam de fora.
Saída (stdout): JSON [{tipo, n_os, cods:[{cod, n_os, n_linhas}]}] para o painel.

  ssh arka "python3 -c \"import base64;exec(base64.b64decode('<script>'))\"" < data/HISTORICO-OS-MEDIDAS.csv > painel-medidor/estilos_historicos.json
"""
import sys, io, re, csv, json, subprocess, unicodedata
from collections import defaultdict, Counter


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", "supabase-db", "psql", "-U", "postgres", "-d", "postgres", "-At"],
                       input=f"set default_transaction_read_only = on;\nselect coalesce(json_agg(t),'[]') from ({q}) t;",
                       capture_output=True, text=True, check=True)
    return json.loads(" ".join(l for l in r.stdout.splitlines() if l.strip() != "SET"))


def norm(s):
    s = unicodedata.normalize("NFD", (s or "").lower())
    return "".join(c for c in s if unicodedata.category(c) != "Mn")


TIPOS = [
    ("Caminhao limpa-fossa", ["limpa fossa", "limpa-fossa", "caminhao", "fossa"]),
    ("Desentupimento", ["desentup", "entupid", "entupi"]),
    ("Quadro branco/Mobiliario", ["quadro branco", "quadro de aula", "mural", "mobiliario", "armario", "estante", "prateleira"]),
    ("Ar condicionado (rede)", ["ar condicionado", "ar-condicionado", "split", "btu"]),
    ("Bebedouro/Filtro", ["bebedouro", "filtro"]),
    ("Bomba dagua/Boia", ["bomba", "boia"]),
    ("Caixa descarga/Valvula", ["descarga", "valvula", "caixa acoplada"]),
    ("Vaso/Anel de cera", ["vaso", "anel de cera", "assento sanit", "espude", "spud"]),
    ("Sifao", ["sifao"]),
    ("Torneira", ["torneira"]),
    ("Caixa gordura/ralo", ["caixa de gordura", "ralo"]),
    ("Disjuntor", ["disjuntor", "quadro de energia", "quadro de luz"]),
    ("Lampada/Luminaria", ["lampada", "luminaria", "refletor", "reator", "bocal", "spot", "iluminac"]),
    ("Tomada/Interruptor/Ponto", ["tomada", "interruptor", "ponto eletric", "ponto de energia"]),
    ("Ventilador/Dimmer", ["ventilador", "dimmer"]),
    ("Fechadura", ["fechadura", "macaneta", "cadeado", "trinco", "tranca"]),
    ("Vidro", ["vidro", "vidraca"]),
    ("Solda/Serralheria", ["solda", "serralh", "portao", "grade", "alambrado", "corrimao", "trave"]),
    ("Reparo porta/dobradica", ["porta", "dobradica", "mola aerea"]),
    ("Telha/Telhado/Calha", ["telha", "telhado", "calha", "rufo", "cumeeira", "goteira"]),
    ("Forro (PVC/gesso)", ["forro", "gesso"]),
    ("Piso/Revestimento", ["piso", "ceramica", "porcelanato", "azulejo", "revestiment", "rejunte"]),
    ("Pintura esmalte/verniz", ["esmalte", "verniz"]),
    ("Pintura latex", ["pintura", "pintar", "pintad", "tinta", "latex", "massa corrida"]),
]


def tipo(o):  # mesma ordem de prioridade da Mestra: serviço, depois o pedido, depois o material
    for texto in (o.get("servico"), o.get("solicitado"), o.get("materiais")):
        t = norm(texto)
        if not t.strip():
            continue
        for nome, pal in TIPOS:
            if any(p in t for p in pal):
                return nome
    return ""


def chave(s):
    s = re.sub(r"(?i)emerg[eê]ncial|o\.?\s*s\.?\s*n?[°º]?", "", s or "")
    return re.sub(r"[^A-Z0-9]", "", s.upper()).lstrip("0") or ""


OS = sql("select id, numero, numero_fict, fict_ref, servico, solicitado, materiais from os_campo where coalesce(excluida,false)=false")
por_chave = defaultdict(list)
for o in OS:
    if o.get("numero") is not None:
        por_chave[str(o["numero"])].append(o)
    if o.get("fict_ref"):
        por_chave[chave(o["fict_ref"])].append(o)

linhas = list(csv.DictReader(io.StringIO(sys.stdin.buffer.read().decode("utf-8-sig")), delimiter=";"))
os_por_tipo = defaultdict(set)
uso = defaultdict(lambda: defaultdict(lambda: [set(), 0]))   # tipo -> cod -> [O.S. distintas, linhas]
ligadas = 0
for r in linhas:
    ref = (r.get("os_ref") or "").strip()
    if not re.fullmatch(r"(?i)(o\.?\s*s\.?\s*n?[°º]?\s*)?[0-9]{1,4}|[LMGCFQNPE]\s*-?\s*[0-9]{1,4}", ref):
        continue
    alvo = por_chave.get(chave(ref))
    if not alvo or len(alvo) > 1:      # não existe, ou nº duplicado no sistema: não arrisca
        continue
    o = alvo[0]
    t = tipo(o)
    if not t:
        continue
    ligadas += 1
    os_id = (r["medicao"], o["id"])
    os_por_tipo[t].add(os_id)
    u = uso[t][r["codigo_emop"].strip()]
    u[0].add(os_id)
    u[1] += 1

saida = []
for t, cods in uso.items():
    n_os = len(os_por_tipo[t])
    lista = sorted(({"cod": c, "n_os": len(v[0]), "n_linhas": v[1]} for c, v in cods.items()), key=lambda x: (-x["n_os"], -x["n_linhas"]))
    lista = [x for x in lista if x["n_os"] >= 2][:5]
    if lista:
        saida.append({"tipo": t, "n_os": n_os, "cods": lista})
saida.sort(key=lambda x: -x["n_os"])
print(json.dumps({"fonte": "MED 01-09 (memória de cálculo aceita) x serviço das O.S. no sistema",
                  "linhas_historico": len(linhas), "linhas_ligadas": ligadas, "estilos": saida}, ensure_ascii=False))
