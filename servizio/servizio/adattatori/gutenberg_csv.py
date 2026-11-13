"""Project Gutenberg: catalogo ufficiale offline (pg_catalog.csv), pensato per l'uso automatico.

Incrementale: dopo la prima esecuzione considera solo i libri con data «Issued» successiva all'ultimo controllo."""
from __future__ import annotations

import csv
import io

from ..modello import nuovo_candidato

LINGUE = {"en", "it", "fr", "de", "la", "es", "el"}


def cerca(fonte: dict, ricerche: list[str], fetcher, adesso: str, ultimo_controllo: str | None,
          parole_chiave: list[str] | None = None) -> list[dict]:
    parole = [p.lower() for p in (parole_chiave or fonte.get("parole_chiave") or [])]
    testo = fetcher.get_testo(fonte["url"])
    out = []
    for r in csv.DictReader(io.StringIO(testo)):
        if r.get("Type") != "Text":
            continue
        if ultimo_controllo and (r.get("Issued") or "") <= ultimo_controllo[:10]:
            continue
        campi = " ".join((r.get("Title", ""), r.get("Subjects", ""), r.get("Bookshelves", ""))).lower()
        trovata = next((p for p in parole if p in campi), None)
        if not trovata:
            continue
        lingue = {x.strip() for x in (r.get("Language") or "").split(";")}
        if lingue and not (lingue & LINGUE):
            continue
        n = r["Text#"].strip()
        out.append(nuovo_candidato(
            fonte["id"], n, adesso,
            titolo=" ".join((r.get("Title") or "").split()), autore=r.get("Authors", ""),
            anno="", lingua=",".join(sorted(lingue)), formato="epub",
            url_scheda=f"https://www.gutenberg.org/ebooks/{n}",
            url_download=f"https://www.gutenberg.org/cache/epub/{n}/pg{n}.epub",
            integrale=True, verifica="catalogo",
            motivo=f"Argomento «{trovata}» nel catalogo Gutenberg (dominio pubblico)",
        ))
    return out
