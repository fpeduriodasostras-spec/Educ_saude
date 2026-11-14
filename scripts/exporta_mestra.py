#!/usr/bin/env python3
"""Exporta a PLANILHA MESTRA FP.094 em JSON para o painel "Planilha Mestra" (front/mestra.html).

Para o painel bater ao centavo com o Excel que a equipe já recebe, este script NÃO reescreve as
regras: ele roda o próprio /root/fpv-mestra/gerar_mestra.py e troca SÓ a linha que grava o .xlsx
(`wb.save(caminho)`) por uma exportação em JSON no stdout. Nada é gravado no servidor e a consulta
ao banco continua em transação read-only (função sql() do gerador).

  ssh arka "python3 - MED 12 2026-11-02 2026-12-01" < exporta_mestra.py > mestra_med12.json
"""
import sys, json, re
from collections import Counter

FONTE = "/root/fpv-mestra/gerar_mestra.py"
src = open(FONTE, encoding="utf-8").read()
if src.count("wb.save(caminho)") != 1:
    sys.exit("gerar_mestra.py mudou: não achei exatamente um 'wb.save(caminho)' — conferir antes de exportar")
src = src.replace("wb.save(caminho)", "__exporta__(globals()); raise SystemExit(0)")


def __exporta__(g):
    ref, br, material_auto, falta, completa = g["ref"], g["br"], g["material_auto"], g["falta"], g["completa"]
    med_and, med_sem, prontas, completar = g["med_and"], g["med_sem"], g["prontas"], g["completar"]
    aguard, vinc, todas, barradas = g["aguard"], g["vinc"], g["todas"], g["barradas"]
    ids = lambda lst: {o["id"] for o in lst}
    grupos = {"and": ids(med_and), "pronta": ids(prontas), "completar": ids(completar), "sem": ids(med_sem),
              "aguard": ids(aguard), "vinc": ids(vinc), "barrada": ids(barradas)}
    linhas = []
    for o in todas:
        mat, qt, valid = material_auto(o)
        fotos = [u for u in (o.get("foto_urls") or []) if u]
        ab = [k for k, s in grupos.items() if o["id"] in s]
        r = {"id": o["id"], "os": ref(o), "un": o.get("unidade") or "", "fi": o.get("fiscal") or "",
             "cl": o.get("classificacao") or "", "en": br(o.get("entrada")), "co": br(o.get("conclusao")),
             "ex": o.get("executor") or "", "st": o.get("status") or "", "me": o.get("medicao") or "",
             "so": o.get("solicitado") or "", "se": o.get("servico") or "", "ma": o.get("materiais") or "",
             "al": mat or "", "qi": qt or "", "mc": o.get("memoria_calculo") or "",
             "as": "SIM" if o.get("assinado") else "", "va": valid or "", "ft": fotos, "ab": ab}
        if "and" in ab or "sem" in ab:
            # (12/11) sugestão do motor p/ o Painel do Medidor — é PALPITE (fica em azul, "sugestão"),
            # o código que vale é o que o medidor lança; a Mestra em Excel continua com TIPO/CÓDIGO em branco
            r["ti"], r["cs"] = g["tipo_emop"](o)
        if "completar" in ab or "sem" in ab:
            r["fa"] = falta(o)
            if "sem" in ab:
                r["si"] = "PRONTA" if completa(o) else "falta: " + falta(o)
        if o.get("par_sugerido"):
            r["pr"] = str(o["par_sugerido"])
        if o.get("fict_ref"):
            r["fr"] = o["fict_ref"]
        linhas.append(r)
    lin_os = lambda o, quem: [o.get("status") or "", ref(o), o.get("unidade") or "", o.get(quem) or "", (o.get("solicitado") or "")[:160]]
    saida = {
        "meta": {"med": g["MED"], "ini": g["INI"].strftime("%d/%m/%Y"), "fim": g["FIM"].strftime("%d/%m/%Y"),
                 "gerado_em": g["AGORA"].strftime("%d/%m/%Y %H:%M"), "versao": g["VERSAO"],
                 "fonte": "banco central (VPS), tabela os_campo, só leitura — mesmas regras do gerar_mestra.py"},
        "resumo": [[k, v] for k, v in g["resumo"]],
        "med_futura": dict(g["med_estranha"]),
        "problemas": g["problemas"],
        "emitidas_sem_baixa": [lin_os(o, "fiscal") for o in sorted(g["emit"], key=lambda o: o["numero"])],
        "executando_sem_numero": [lin_os(o, "executor") for o in sorted(g["exec_sem"], key=ref)],
        "reapresentar": g["reap"],
        "os": linhas,
    }
    json.dump(saida, sys.stdout, ensure_ascii=False, default=str)


sys.argv = ["gerar_mestra.py"] + sys.argv[1:5] + ["/root/fpv-mestra", "PAINEL"]
exec(compile(src, FONTE, "exec"), {"__name__": "__main__", "__exporta__": __exporta__})
