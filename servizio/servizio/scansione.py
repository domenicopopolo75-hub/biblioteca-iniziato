"""Scansione mensile: ogni fonte è isolata; un guasto non blocca le altre; mai download di libri."""
from __future__ import annotations

from datetime import datetime

from . import fonti as reg_fonti
from .adattatori import ADATTATORI
from .archivio import Archivio
from .modello import (APPROVATO, IMPORTATO, PROPOSTO, RINVIATO, chiave_opera, versione_candidato)


def _ora(d: datetime) -> str:
    return d.astimezone().isoformat(timespec="seconds")


def esegui_scansione(archivio: Archivio, registro: dict, fetcher, adesso: datetime,
                     adattatori: dict | None = None) -> dict:
    adattatori = adattatori or ADATTATORI
    ora = _ora(adesso)
    candidati = archivio.leggi("candidati")
    inventario = {chiave_opera(x.get("titolo", ""), x.get("autore", "")) for x in archivio.leggi("inventario")}
    checkpoint = archivio.leggi("checkpoint")
    run = {"id": ora, "iniziata": ora, "fonti": {}, "nuovi": [], "gia_in_biblioteca": 0, "gia_proposti": 0}

    attive = reg_fonti.attive(registro)
    for f in attive:
        esito = {"stato": "ok", "trovati": 0, "nuovi": 0}
        try:
            trovati = adattatori[f["adattatore"]](f, registro.get("ricerche", []), fetcher, ora,
                                                  checkpoint.get(f["id"]))
            esito["trovati"] = len(trovati)
            for c in trovati:
                if chiave_opera(c["titolo"], c["autore"]) in inventario and c["titolo"]:
                    run["gia_in_biblioteca"] += 1
                    continue
                if c["id"] in candidati:
                    run["gia_proposti"] += 1
                    continue
                candidati[c["id"]] = c
                run["nuovi"].append(c["id"])
                esito["nuovi"] += 1
            checkpoint[f["id"]] = ora  # avanza solo se la fonte è andata a buon fine
        except Exception as e:  # noqa: BLE001 - isolamento della fonte
            esito = {"stato": "fallita", "errore": f"{type(e).__name__}: {e}"[:300], "trovati": 0, "nuovi": 0}
        run["fonti"][f["id"]] = esito

    ok = sum(1 for e in run["fonti"].values() if e["stato"] == "ok")
    run["copertura"] = {"controllate": ok, "fallite": len(attive) - ok, "attive": len(attive),
                        **reg_fonti.copertura(registro)}
    run["completa"] = ok == len(attive) == len(registro["fonti"])  # "completa" solo se TUTTE le fonti registrate
    run["riuscita"] = ok > 0
    run["terminata"] = _ora(datetime.now().astimezone())

    archivio.scrivi("candidati", candidati)
    archivio.scrivi("checkpoint", checkpoint)
    esecuzioni = archivio.leggi("esecuzioni")
    esecuzioni.append(run)
    archivio.scrivi("esecuzioni", esecuzioni)
    return run


def rapporto(run: dict, candidati: dict) -> str:
    c = run["copertura"]
    r = [f"# Scansione del {run['iniziata'][:10]}", "",
         f"Fonti controllate: {c['controllate']} di {c['attive']} attive "
         f"({c['fonti_registrate']} registrate; {len(c['da_implementare'])} senza adattatore).",
         "Copertura: **parziale**." if not run["completa"] else "Copertura: completa.", ""]
    for fid, e in run["fonti"].items():
        r.append(f"- {fid}: {e['stato']} — trovati {e['trovati']}, nuovi {e['nuovi']}" +
                 (f" — {e['errore']}" if e.get("errore") else ""))
    r.append("")
    if run["nuovi"]:
        r.append(f"## Da approvare ({len(run['nuovi'])})")
        for cid in run["nuovi"][:100]:
            x = candidati[cid]
            r.append(f"- `{cid}` {x['titolo']} — {x['autore'] or 's.a.'} [{x['lingua'] or '?'}, {x['formato'] or '?'}] "
                     f"({x['fonte_id']}) — {x['motivo']}")
        if len(run["nuovi"]) > 100:
            r.append(f"- … altri {len(run['nuovi']) - 100} nell'archivio")
    else:
        r.append("Nessun candidato nuovo questo mese.")
    return "\n".join(r)
