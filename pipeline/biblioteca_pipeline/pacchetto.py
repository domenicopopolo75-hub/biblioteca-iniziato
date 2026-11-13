"""Costruzione del pacchetto `.bibl.json` (formato documentato in docs/FORMATO_PACCHETTO.md)."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os

from . import __version__
from .epub import estrai_epub
from .pdf import estrai_pdf
from .txt import estrai_txt

FORMATO = "biblioteca-pacchetto/1"


def sha256_file(percorso: str) -> str:
    h = hashlib.sha256()
    with open(percorso, "rb") as f:
        for pezzo in iter(lambda: f.read(1 << 20), b""):
            h.update(pezzo)
    return h.hexdigest()


def crea_pacchetto(percorso: str, *, title: str | None = None, author: str | None = None,
                   language: str | None = None, provenance: str | None = None) -> dict:
    est = os.path.splitext(percorso)[1].lower()
    if est == ".pdf":
        fmt, dati = "pdf", estrai_pdf(percorso)
    elif est == ".epub":
        fmt, dati = "epub", estrai_epub(percorso)
    elif est in (".txt", ".md", ".text"):
        fmt, dati = "txt", estrai_txt(percorso)
    else:
        raise ValueError(f"formato non supportato: {est}")
    meta = dati.get("meta", {})
    lang = language or meta.get("language") or None
    for b in dati["blocks"]:
        b["lang"] = b["lang"] or lang
    sha = sha256_file(percorso)
    return {
        "format": FORMATO,
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": {"name": "pipeline", "version": __version__},
        "work": {"title": title or meta.get("title") or os.path.splitext(os.path.basename(percorso))[0],
                 "author": author or meta.get("author"), "language": lang},
        "edition": {"id": f"sha256:{sha}", "source_file": os.path.basename(percorso),
                    "source_sha256": sha, "format": fmt, "provenance": provenance,
                    "pages_total": dati["pages_total"]},
        "coverage": dati["coverage"],
        "blocks": dati["blocks"],
    }


def scrivi(pacchetto: dict, destinazione: str) -> None:
    with open(destinazione, "w", encoding="utf-8") as f:
        json.dump(pacchetto, f, ensure_ascii=False, indent=1)
