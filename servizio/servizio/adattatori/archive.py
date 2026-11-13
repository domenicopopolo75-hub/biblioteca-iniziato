"""Internet Archive: ricerca avanzata (metadati). Il file da scaricare si risolve solo dopo l'approvazione."""
from __future__ import annotations

import json
import urllib.parse

from ..modello import nuovo_candidato

BASE = "https://archive.org/advancedsearch.php"


def cerca(fonte: dict, ricerche: list[str], fetcher, adesso: str, ultimo_controllo: str | None) -> list[dict]:
    out: dict[str, dict] = {}
    for q in ricerche:
        query = f'({q}) AND mediatype:texts AND -access-restricted-item:true'
        if ultimo_controllo:
            query += f" AND addeddate:[{ultimo_controllo[:10]} TO 9999-12-31]"
        url = BASE + "?" + urllib.parse.urlencode(
            [("q", query), ("fl[]", "identifier"), ("fl[]", "title"), ("fl[]", "creator"),
             ("fl[]", "year"), ("fl[]", "language"), ("rows", "50"), ("output", "json")])
        dati = json.loads(fetcher.get_testo(url))
        for d in dati.get("response", {}).get("docs", []):
            ident = d["identifier"]
            creator = d.get("creator", "")
            c = nuovo_candidato(
                fonte["id"], ident, adesso,
                titolo=d.get("title", ""), autore="; ".join(creator) if isinstance(creator, list) else creator,
                anno=str(d.get("year", "")), lingua=str(d.get("language", "")), formato="",
                url_scheda=f"https://archive.org/details/{ident}", url_download="",
                integrale=None, verifica="catalogo", argomenti=q,
                motivo=f"Corrisponde alla ricerca «{q}»; file scaricabile da verificare",
            )
            out.setdefault(c["id"], c)
    return list(out.values())
