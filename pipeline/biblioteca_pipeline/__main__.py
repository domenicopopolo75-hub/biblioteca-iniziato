"""Uso: python -m biblioteca_pipeline ORIGINALE [--out FILE] [--title T] [--author A] [--lang it]
           [--provenance P] [--anteprima N]

Crea il pacchetto `.bibl.json` accanto all'originale (o in --out). --anteprima stampa i primi N blocchi
in ordine di lettura per il controllo a vista contro il PDF.
"""
from __future__ import annotations

import argparse
import os

from .pacchetto import crea_pacchetto, scrivi


def main() -> None:
    ap = argparse.ArgumentParser(prog="biblioteca_pipeline")
    ap.add_argument("originale")
    ap.add_argument("--out")
    ap.add_argument("--title")
    ap.add_argument("--author")
    ap.add_argument("--lang")
    ap.add_argument("--provenance")
    ap.add_argument("--anteprima", type=int, default=0)
    a = ap.parse_args()
    p = crea_pacchetto(a.originale, title=a.title, author=a.author, language=a.lang,
                       provenance=a.provenance)
    out = a.out or os.path.splitext(a.originale)[0] + ".bibl.json"
    scrivi(p, out)
    c = p["coverage"]
    print(f"{out}: {len(p['blocks'])} blocchi, unità {c['units_with_text']}/{c['units_total']} con testo, "
          f"vuote {c['units_empty']}, da OCR {c['units_need_ocr']}")
    for b in p["blocks"][: a.anteprima]:
        loc = b["locator"]
        print(f"[{b['order']:4d}] p{loc['page_index']} c{loc['column']} {b['kind']:9s} {b['text'][:90]}")


if __name__ == "__main__":
    main()
