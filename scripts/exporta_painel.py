#!/usr/bin/env python3
"""Exporta as O.S. de uma medição da EDUCAÇÃO (FP.094) do banco central (supabase-db da VPS)
para o painel "Motor de Medição FPV".

SÓ LEITURA: a consulta roda em transação read-only e o script NÃO grava nada no servidor —
tudo sai no stdout. Roda pelo ssh, sem copiar arquivo para a VPS:

  ssh arka "python3 - MED 12 2026-11-02 2026-12-01 os"    < exporta_painel.py > os_med12.json
  ssh arka "python3 - MED 12 2026-11-02 2026-12-01 fotos" < exporta_painel.py > fotos.tsv

modo "os"    -> JSON {meta, os:[...]} no formato que o painel lê (front/data/os_medNN.json)
modo "fotos" -> uma linha por O.S.: <id> TAB <JSON com as miniaturas em data URI>
                (o painel não consegue abrir imagem de fora; por isso vão miniaturas embutidas)

As regras de quem entra na medição são as MESMAS do gerar_mestra.py (/root/fpv-mestra):
etiqueta MED n no app OU concluída/assinatura/avaliando com conclusão no período; Saúde fora;
trava anti-medição dupla pelas listas aprovadas_*.csv do Edmar. Nada é inventado: o que não
está no banco aparece como "falta"; análise fora do banco vem marcada como ANÁLISE.
"""
import sys, json, re, subprocess, unicodedata, glob, csv, base64, io
from datetime import date, datetime
from zoneinfo import ZoneInfo
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import urllib.request

MED = f"{sys.argv[1]} {sys.argv[2]}"            # "MED 12"
INI = date.fromisoformat(sys.argv[3])
FIM = date.fromisoformat(sys.argv[4])
MODO = sys.argv[5] if len(sys.argv) > 5 else "os"
# (11/11) contrato: "edu" (Educação FP.094, padrão) ou "saude" (Saúde FP.096, contrato 005/2026).
# Na Saúde não existe nº oficial de O.S. (a referência é a do executor: NS34, QS43…), não há
# listas de aprovadas e a medição é o mês fechado (MED 09 = 01/11 a 30/11).
CONTRATO = sys.argv[6] if len(sys.argv) > 6 else "edu"
# (12/11) tamanho das miniaturas: 360 (navegar) ou 640 = "VGA", o tamanho pedido no relatório fotográfico oficial
TAM = int(sys.argv[7]) if len(sys.argv) > 7 else 360
SAUDE = CONTRATO == "saude"
PASTA = "/root/fpv-mestra"
AGORA = datetime.now(ZoneInfo("America/Sao_Paulo"))


def sql(q):
    r = subprocess.run(["docker", "exec", "-i", "supabase-db", "psql", "-U", "postgres", "-d", "postgres", "-At"],
                       input=f"set default_transaction_read_only = on;\nselect coalesce(json_agg(t),'[]') from ({q}) t;",
                       capture_output=True, text=True, check=True)
    corpo = " ".join(l for l in r.stdout.splitlines() if l.strip() != "SET")
    return json.loads(corpo)


def norm(s):
    s = unicodedata.normalize("NFD", (s or "").lower())
    return "".join(c for c in s if unicodedata.category(c) != "Mn")


def chave_escola(s):
    tipos = {"escola", "e", "m", "em", "creche", "municipal", "ciep", "de", "da", "do", "dos", "das"}
    return " ".join(p for p in re.split(r"[^a-z0-9]+", norm(s)) if p and p not in tipos)


UNIDADES_SAUDE = [
    "SEMUSA (Sede)", "Hospital Municipal Naelma Monteira (HMNM)", "Pronto Socorro Maria Rosa da Conceição",
    "UPA Valmir Hespanhol", "Farmácia Municipal", "Resgate 24h", "ESF Âncora", "ESF Cantagalo",
    "ESF Cidade Praiana", "ESF Cláudio Ribeiro", "Clínica da Família Paulo H. Gussen", "ESF Dona Edimeia (Edméia)",
    "ESF Mar do Norte", "ESF Nova Cidade", "ESF Operário", "ESF Recanto", "ESF Rocha Leão", "UBS Boca da Barra",
    "UBS Jardim Mariléia", "UBS Nova Esperança", "UBS Nilson Gonçalves Marins", "Extensão do Bosque (Sal Sal)",
    "Ambulatório de Saúde Mental", "CAPS", "CAPSI Rui Ribeiro de Freitas",
    "Centro de Reabilitação Rocha Leão (Cória Gomes)", "Centro de Reabilitação Laércio Lúcio de Carvalho",
    "NASCA (Saúde da Criança e Adolescente)", "Residência Terapêutica I", "Residência Terapêutica II",
    "COGA (Gestão Auditoria)", "DESGE", "Galpão Recanto", "Prefeitura", "Caminhão Catarata / Tenda (eventos)",
    "Pré-Operatório", "Casa de Recuperação", "Casa da Criança",
]
SAUDE_CHAVES = {chave_escola(u) for u in UNIDADES_SAUDE}


def eh_saude(o):
    if (o.get("contrato") or "").strip().lower().startswith("sa"):
        return True
    return chave_escola(o.get("unidade") or "") in SAUDE_CHAVES


def ref(o):
    if o.get("numero") is not None:
        return str(o["numero"])
    return o.get("fict_ref") or (f"F-{o['numero_fict']}" if o.get("numero_fict") else "S/Nº")


def br(d):
    if not d:
        return ""
    try:
        return date.fromisoformat(str(d)[:10]).strftime("%d/%m/%Y")
    except ValueError:
        return str(d)


def data(d):
    try:
        return date.fromisoformat(str(d)[:10]) if d else None
    except ValueError:
        return None


# TIPO (GUIA EMOP) -> CÓDIGO (SUGESTÃO): mesma tabela do gerar_mestra.py (Mestra MED 10 do Renan)
TIPOS = [
    ("Caminhao limpa-fossa", ["limpa fossa", "limpa-fossa", "caminhao", "fossa"], "NAO-EMOP: terceirizado"),
    ("Desentupimento", ["desentup", "entupid", "entupi"], "NAO-EMOP: mao de obra"),
    ("Quadro branco/Mobiliario", ["quadro branco", "quadro de aula", "mural", "mobiliario", "armario", "estante", "prateleira"], "NAO-EMOP: mobiliario"),
    ("Ar condicionado (rede)", ["ar condicionado", "ar-condicionado", "split", "btu"], "15.005.0215 + cabos"),
    ("Bebedouro/Filtro", ["bebedouro", "filtro"], "18.017.0020 / 15.004.0255"),
    ("Bomba dagua/Boia", ["bomba", "boia"], "18.029.0012 / 18.012.0090"),
    ("Caixa descarga/Valvula", ["descarga", "valvula", "caixa acoplada"], "18.019.0010 / 18.003.0003"),
    ("Vaso/Anel de cera", ["vaso", "anel de cera", "assento sanit", "espude", "spud"], "15.004.0108 / 18.002"),
    ("Sifao", ["sifao"], "18.013.0127"),
    ("Torneira", ["torneira"], "18.009/18.008"),
    ("Caixa gordura/ralo", ["caixa de gordura", "ralo"], "15.002.0062/0063"),
    ("Disjuntor", ["disjuntor", "quadro de energia", "quadro de luz"], "15.007.0570..0611"),
    ("Lampada/Luminaria", ["lampada", "luminaria", "refletor", "reator", "bocal", "spot", "iluminac"], "15.020.0173/0170/0158"),
    ("Tomada/Interruptor/Ponto", ["tomada", "interruptor", "ponto eletric", "ponto de energia"], "15.015.0250/0255"),
    ("Ventilador/Dimmer", ["ventilador", "dimmer"], "(definir codigo c/ Renan)"),
    ("Fechadura", ["fechadura", "macaneta", "cadeado", "trinco", "tranca"], "14.007.0036/0041/0065"),
    ("Vidro", ["vidro", "vidraca"], "14.004.0120/0121"),
    ("Solda/Serralheria", ["solda", "serralh", "portao", "grade", "alambrado", "corrimao", "trave"], "14.002.0010/0071/0132"),
    ("Reparo porta/dobradica", ["porta", "dobradica", "mola aerea"], "14.013/14.006/14.007"),
    ("Telha/Telhado/Calha", ["telha", "telhado", "calha", "rufo", "cumeeira", "goteira"], "16.002/16.004"),
    ("Forro (PVC/gesso)", ["forro", "gesso"], "13.175/13.180"),
    ("Piso/Revestimento", ["piso", "ceramica", "porcelanato", "azulejo", "revestiment", "rejunte"], "13.330/13.030"),
    ("Pintura esmalte/verniz", ["esmalte", "verniz"], "17.017.0320/0110"),
    ("Pintura latex", ["pintura", "pintar", "pintad", "tinta", "latex", "massa corrida"], "17.018.0031/0185"),
]


def tipo_emop(o):
    for texto, sufixo in ((o.get("servico"), ""), (o.get("solicitado"), " (pelo solicitado)"), (o.get("materiais"), " (pelo material)")):
        t = norm(texto)
        if not t.strip():
            continue
        for nome, palavras, codigo in TIPOS:
            if any(p in t for p in palavras):
                return nome, codigo + sufixo
    return "", ""


def tem_conteudo(s):
    # regra do Leony (03/11): qualquer coisa escrita conta; não conta vazia nem só o modelo "___ x ___ = ___ m²"
    s = re.sub(r"_{3}\s*x\s*_{3}\s*=\s*_{3}\s*m²", "", s or "")
    return bool(s.replace("___", "").strip())


def como_memoria(o):
    m = (o.get("memoria_calculo") or "").strip()
    if not re.sub(r"[\s.,;:\-—]", "", m):
        return "memória de cálculo"
    if "___" in m:
        return "memória de cálculo (só o modelo do app)"
    return "memória sem quantidade"


def fotos_de(o):
    return [u for u in (o.get("foto_urls") or []) if u]


# ---- trava anti-medição dupla (listas do Edmar em /root/fpv-mestra/aprovadas_*.csv: med;os;escola)
def chave_os(s):
    s = re.sub(r"(?i)emerg[eê]ncial", "", s or "")
    return re.sub(r"[^A-Z0-9]", "", s.upper())


def _lista(nome, campo):
    d = {}
    for arq in glob.glob(f"{PASTA}/{nome}"):
        with open(arq, encoding="utf-8-sig") as f:
            for r in csv.DictReader(f, delimiter=";"):
                if (r.get("os") or "").strip():
                    d[chave_os(r["os"])] = (r.get(campo) or "").strip()
    return d


FEITO = {"Concluído", "Assinatura", "Avaliando"}


def no_periodo(o):
    c = data(o.get("conclusao"))
    return o.get("status") in FEITO and c is not None and INI <= c <= FIM


def da_med(o):
    return (o.get("medicao") or "").strip() == MED or no_periodo(o)


# ================= dados =================
OS = sql("select * from os_campo where coalesce(excluida,false) = false")
edu = [o for o in OS if eh_saude(o) == SAUDE and o.get("status") != "Cancelada"]
sel = [o for o in edu if da_med(o)]
sel.sort(key=lambda o: (o.get("numero") is None, o.get("numero") or 0, ref(o)))

if MODO == "fotos":
    from PIL import Image, ImageOps

    def miniatura(url):
        try:
            with urllib.request.urlopen(url, timeout=40) as r:
                img = Image.open(io.BytesIO(r.read()))
                img = ImageOps.exif_transpose(img).convert("RGB")
                img.thumbnail((TAM, TAM))
                buf = io.BytesIO()
                img.save(buf, "JPEG", quality=62 if TAM <= 360 else 68, optimize=True)
                return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()
        except Exception:
            return None

    with ThreadPoolExecutor(8) as ex:
        for o in sel:
            urls = fotos_de(o)
            if not urls:
                continue
            mins = list(ex.map(miniatura, urls))
            print(f"{o['id']}\t{json.dumps(mins)}", flush=True)
    sys.exit(0)

APROVADAS = defaultdict(set)
for arq in ([] if SAUDE else glob.glob(f"{PASTA}/aprovadas_*.csv")):
    with open(arq, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f, delimiter=";"):
            if (r.get("os") or "").strip():
                APROVADAS[chave_os(r["os"])].add((r.get("med") or "").strip())
for o in OS:
    if o.get("par_sugerido") and chave_os(ref(o)) in APROVADAS:
        APROVADAS[chave_os(str(o["par_sugerido"]))] |= APROVADAS[chave_os(ref(o))]


def ja_aprovada(o):
    return sorted(m for m in APROVADAS.get(chave_os(ref(o)), set()) if m and m != MED)


ALERTA = {} if SAUDE else _lista("alertas_med.csv", "alerta")
for k, v in ({} if SAUDE else _lista("nao_apresentar.csv", "motivo")).items():
    ALERTA[k] = (ALERTA[k] + "; " if k in ALERTA else "") + "CONFERIR: " + v

SAIDAS = sql("select descricao, quantidade, unidade, os_ref, escola, data from saida_material")
saidas_por_ref = defaultdict(list)
for s in SAIDAS:
    r = re.sub(r"^O\.?S\.?\s*", "", (s.get("os_ref") or "").strip(), flags=re.I)
    if r:
        saidas_por_ref[r].append(s)


def almox(o):
    ss = saidas_por_ref.get(ref(o), [])
    return " · ".join(f"{float(s.get('quantidade') or 0):.2f}".replace(".", ",") + f" {s.get('unidade') or ''} {s.get('descricao') or ''}".rstrip() for s in ss)


saida = []
for o in sel:
    fotos = fotos_de(o)
    etiqueta = (o.get("medicao") or "").strip()
    barrada = ja_aprovada(o)
    falta = []
    if o.get("numero") is None and not SAUDE:
        falta.append("nº oficial")
    if o.get("status") != "Concluído":
        falta.append(f"concluir (está {o.get('status')})")
    if not tem_conteudo(o.get("memoria_calculo")):
        falta.append(como_memoria(o))
    if len(fotos) < 3:
        falta.append(f"fotos ({len(fotos)} de 3)")
    if not (o.get("executor") or "").strip():
        falta.append("executor")
    alertas = []
    if etiqueta and etiqueta != MED:
        alertas.append(f"no app está etiquetada {etiqueta}")
    if barrada:
        alertas.append(f"JÁ APROVADA em {' + '.join(barrada)} (lista do Edmar) — não medir de novo")
    analise = ALERTA.get(chave_os(ref(o)), "")
    tipo, codsug = tipo_emop(o)
    saida.append({
        "id": o["id"],
        "os": ref(o),
        "grupo": "com_numero" if o.get("numero") is not None else "sem_numero",
        "unidade": o.get("unidade") or "",
        "fiscal": o.get("fiscal") or "",
        "entrada": br(o.get("entrada")),
        "conclusao": br(o.get("conclusao")),
        "resp": o.get("executor") or "",
        "status": o.get("status") or "",
        "etiqueta": etiqueta,
        "solicitado": o.get("solicitado") or "",
        "servico": o.get("servico") or "",
        "materiais": o.get("materiais") or "",
        "almox": almox(o),
        "qtde": "",
        "tipo": tipo,
        "codsug": codsug,
        "memoria": o.get("memoria_calculo") or "",
        "assinada": "sim" if o.get("assinado") else "",
        "fotos_url": fotos,
        "falta": falta,
        "alertas": alertas,
        "analise": ("ANÁLISE (não está no banco): " + analise) if analise else "",
        "barrada": bool(barrada),
        "pronta": not falta and not alertas and not analise,
    })

meta = {
    "med": MED,
    "contrato": "Saúde FP.096 · contrato 005/2026" if SAUDE else "Educação FP.094 · contrato 064/2025",
    "contratante": "SECRETARIA MUNICIPAL DE SAÚDE (SEMUSA) RIO DAS OSTRAS" if SAUDE else "SEMEDE RIO DAS OSTRAS",
    "base": "data/base_saude.json" if SAUDE else "data/base.json",
    "jur": "data/jur_saude.json" if SAUDE else "data/jurisprudencia.json",
    "jur_rotulo": "unidades" if SAUDE else "O.S.",
    "exige_numero": not SAUDE,
    "usa_material": SAUDE,
    "ini": INI.strftime("%d/%m/%Y"),
    "fim": FIM.strftime("%d/%m/%Y"),
    "gerado_em": AGORA.strftime("%d/%m/%Y %H:%M"),
    "fonte": "banco central (VPS) — tabela os_campo, só leitura",
    "regra": f"etiqueta {MED} no app OU concluída/assinatura/avaliando com conclusão entre {INI.strftime('%d/%m')} e {FIM.strftime('%d/%m')}; {'Educação' if SAUDE else 'Saúde'} fora; canceladas fora",
}
json.dump({"meta": meta, "os": saida}, sys.stdout, ensure_ascii=False)
