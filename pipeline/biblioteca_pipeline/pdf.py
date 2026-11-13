"""Estrazione PDF con ricostruzione dell'ordine di lettura (colonne).

Regole:
- intestazioni/piè di pagina ripetuti (stessa chiave, margine alto/basso, >= 30% delle pagine) esclusi;
- ogni pagina è divisa in fasce verticali: un blocco che attraversa la linea centrale del contenuto
  (titolo, testo a piena larghezza) è una fascia a sé; i blocchi stretti consecutivi formano una fascia
  che si legge colonna sinistra dall'alto in basso, poi colonna destra;
- pagine senza testo: `units_need_ocr` se contengono immagini, altrimenti `units_empty`.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from statistics import median

import pymupdf

from .normalizza import chiave_ripetizione, normalizza, numero_stampato, script_dominante

MARGINE = 0.12          # frazione di pagina considerata margine alto/basso
SOGLIA_RIPETUTI = 0.30  # quota minima di pagine per dire "ripetuto"
TOLLERANZA_CENTRO = 8.0  # punti: un blocco "attraversa" il centro se lo supera di almeno tanto


@dataclass
class BloccoPDF:
    page_index: int
    bbox: tuple[float, float, float, float]
    text_raw: str
    size: float
    column: int = 0
    kind: str = "paragraph"
    extra: dict = field(default_factory=dict)


def _blocchi_pagina(pagina: pymupdf.Page, indice: int) -> list[BloccoPDF]:
    out: list[BloccoPDF] = []
    d = pagina.get_text("dict")
    for b in d.get("blocks", []):
        if b.get("type") != 0:
            continue
        righe, sizes = [], []
        for line in b.get("lines", []):
            t = "".join(s.get("text", "") for s in line.get("spans", []))
            righe.append(t)
            sizes += [s.get("size", 0) for s in line.get("spans", []) if s.get("text", "").strip()]
        testo = "\n".join(righe)
        if not testo.strip():
            continue
        out.append(BloccoPDF(indice, tuple(round(v, 1) for v in b["bbox"]), testo,
                             median(sizes) if sizes else 0.0))
    return out


def _ripetuti(pagine: list[list[BloccoPDF]], altezze: list[float]) -> set[str]:
    conta: Counter[str] = Counter()
    for blocchi, h in zip(pagine, altezze):
        chiavi = set()
        for b in blocchi:
            if b.bbox[3] <= h * MARGINE or b.bbox[1] >= h * (1 - MARGINE):
                chiavi.add(chiave_ripetizione(b.text_raw))
        conta.update(chiavi)
    n = len(pagine)
    minimo = max(3, int(n * SOGLIA_RIPETUTI + 0.999)) if n >= 3 else n + 1
    return {k for k, c in conta.items() if c >= minimo}


def _ordina_fascia(f: list[BloccoPDF], corpo: float) -> list[BloccoPDF]:
    """Colonna sinistra poi destra. Eccezione: un titolo (corpo grande) della colonna destra che sta
    interamente sopra il primo blocco della sinistra (es. firma/autore accanto al titolo) va prima."""
    sinistra = [b for b in f if b.column == 1]
    destra = [b for b in f if b.column == 2]
    prima = []
    if sinistra and destra and corpo:
        top_sx = min(b.bbox[1] for b in sinistra)
        prima = [b for b in destra if b.size >= corpo * 1.25 and b.bbox[3] <= top_sx + 2]
    resto = [b for b in f if b not in prima]
    return sorted(prima, key=lambda b: b.bbox[1]) + sorted(resto, key=lambda b: (b.column, b.bbox[1], b.bbox[0]))


def _ordina_pagina(blocchi: list[BloccoPDF], corpo: float = 0.0) -> list[BloccoPDF]:
    if not blocchi:
        return []
    x0 = min(b.bbox[0] for b in blocchi)
    x1 = max(b.bbox[2] for b in blocchi)
    centro = (x0 + x1) / 2
    per_y = sorted(blocchi, key=lambda b: (b.bbox[1], b.bbox[0]))
    fasce: list[list[BloccoPDF]] = []
    corrente: list[BloccoPDF] = []
    for b in per_y:
        largo = b.bbox[0] < centro - TOLLERANZA_CENTRO and b.bbox[2] > centro + TOLLERANZA_CENTRO
        if largo:
            if corrente:
                fasce.append(corrente)
                corrente = []
            b.column = 0
            fasce.append([b])
        else:
            b.column = 1 if (b.bbox[0] + b.bbox[2]) / 2 < centro else 2
            corrente.append(b)
    if corrente:
        fasce.append(corrente)
    ordinati: list[BloccoPDF] = []
    for f in fasce:
        ordinati += _ordina_fascia(f, corpo)
    return ordinati


def estrai_pdf(percorso: str) -> dict:
    doc = pymupdf.open(percorso)
    pagine = [_blocchi_pagina(doc[i], i) for i in range(doc.page_count)]
    altezze = [doc[i].rect.height for i in range(doc.page_count)]
    ripetuti = _ripetuti(pagine, altezze)

    tutte_size = [b.size for p in pagine for b in p if b.size]
    corpo = median(tutte_size) if tutte_size else 0.0

    blocks_out, vuote, ocr, con_testo = [], [], [], 0
    stampate: dict[int, str | None] = {}
    order = 0
    for i, blocchi in enumerate(pagine):
        h = altezze[i]
        tenuti = []
        stampata = None
        for b in blocchi:
            nel_margine = b.bbox[3] <= h * MARGINE or b.bbox[1] >= h * (1 - MARGINE)
            if nel_margine and chiave_ripetizione(b.text_raw) in ripetuti:
                stampata = stampata or numero_stampato(b.text_raw)
                continue
            if nel_margine and numero_stampato(b.text_raw) and len(b.text_raw.strip()) <= 4:
                stampata = stampata or b.text_raw.strip()
                continue
            tenuti.append(b)
        stampate[i] = stampata
        if not tenuti:
            (ocr if doc[i].get_images() else vuote).append(i)
            continue
        con_testo += 1
        for n, b in enumerate(_ordina_pagina(tenuti, corpo)):
            if corpo and b.size >= corpo * 1.25:
                b.kind = "heading"
            elif corpo and b.size <= corpo * 0.85:
                b.kind = "note"
            testo = normalizza(b.text_raw)
            if not testo:
                continue
            script = script_dominante(testo)
            if script and b.kind == "heading":
                b.kind = "paragraph"
            blocks_out.append({
                "id": f"p{i:04d}-b{n:04d}",
                "order": order,
                "kind": b.kind,
                "locator": {"page_index": i, "printed_page": stampata, "column": b.column,
                            "bbox": list(b.bbox), "chapter": None, "href": None},
                "lang": script,
                "text_raw": b.text_raw,
                "text": testo,
            })
            order += 1
    return {
        "pages_total": doc.page_count,
        "coverage": {"units_total": doc.page_count, "units_with_text": con_testo,
                     "units_empty": vuote, "units_need_ocr": ocr,
                     "excluded_repeated": sorted(ripetuti)},
        "blocks": blocks_out,
    }
