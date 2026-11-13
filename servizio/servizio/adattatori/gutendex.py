"""Project Gutenberg tramite l'API pubblica Gutendex (JSON)."""
from __future__ import annotations

import json
import urllib.parse

from ..modello import nuovo_candidato

BASE = "https://gutendex.com/books/"


def cerca(fonte: dict, ricerche: list[str], fetcher, adesso: str, ultimo_controllo: str | None) -> list[dict]:
    out: dict[str, dict] = {}
    for q in ricerche:
        url = BASE + "?" + urllib.parse.urlencode({"search": q, "copyright": "false"})
        dati = json.loads(fetcher.get_testo(url))
        for b in dati.get("results", []):
            formati = b.get("formats", {})
            epub = formati.get("application/epub+zip")
            pdf = formati.get("application/pdf")
            dl, fmt = (epub, "epub") if epub else ((pdf, "pdf") if pdf else ("", ""))
            autori = "; ".join(a["name"] for a in b.get("authors", []))
            c = nuovo_candidato(
                fonte["id"], str(b["id"]), adesso,
                titolo=b.get("title", ""), autore=autori, anno="",
                lingua=",".join(b.get("languages", [])), formato=fmt,
                url_scheda=f"https://www.gutenberg.org/ebooks/{b['id']}", url_download=dl or "",
                integrale=True if dl else None, verifica="catalogo",
                motivo=f"Corrisponde alla ricerca «{q}» (dominio pubblico)",
            )
            out.setdefault(c["id"], c)
    return list(out.values())
