"""Testo semplice: un paragrafo per gruppo di righe separato da riga vuota."""
from __future__ import annotations

import re

from .normalizza import normalizza


def estrai_txt(percorso: str) -> dict:
    with open(percorso, "rb") as f:
        dati = f.read()
    try:
        testo = dati.decode("utf-8-sig")
    except UnicodeDecodeError:
        testo = dati.decode("cp1252")
    paragrafi = [p for p in re.split(r"\n\s*\n", testo.replace("\r\n", "\n")) if p.strip()]
    blocks = []
    for n, raw in enumerate(paragrafi):
        t = normalizza(raw)
        kind = "heading" if len(t) < 80 and not t.endswith((".", ":", ";", ",")) and "\n" not in raw.strip() else "paragraph"
        blocks.append({"id": f"t0000-b{n:04d}", "order": n, "kind": kind,
                       "locator": {"page_index": 0, "printed_page": None, "column": 0, "bbox": None,
                                   "chapter": None, "href": None},
                       "lang": None, "text_raw": raw, "text": t})
    return {"pages_total": 1,
            "coverage": {"units_total": 1, "units_with_text": 1 if blocks else 0,
                         "units_empty": [] if blocks else [0], "units_need_ocr": []},
            "blocks": blocks}
