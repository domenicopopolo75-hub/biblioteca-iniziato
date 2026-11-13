"""Scansione mensile: ogni fonte è isolata; un guasto non blocca le altre; mai download di libri."""
from __future__ import annotations

from datetime import datetime

from . import fonti as reg_fonti
from .adattatori import ADATTATORI
from . import rilevanza
from .archivio import Archivio
from .modello import chiave_opera, normalizza


def inventario_iniziale() -> list[dict]:
    import json
    from importlib import resources
    return json.loads(resources.files("servizio").joinpath("inventario_iniziale.json").read_text(encoding="utf-8"))


def _ora(d: datetime) -> str:
    return d.astimezone().isoformat(timespec="seconds")


MOSTRA = 40


def esegui_scansione(archivio: Archivio, registro: dict, fetcher, adesso: datetime,
                     adattatori: dict | None = None) -> dict:
    adattatori = adattatori or ADATTATORI
    ora = _ora(adesso)
    candidati = archivio.leggi("candidati")
    voci_inv = archivio.leggi("inventario") + inventario_iniziale()
    inventario = {chiave_opera(x.get("titolo", ""), x.get("autore", "")) for x in voci_inv}
    titoli_inv = {normalizza(x["titolo"]) for x in voci_inv if len(normalizza(x.get("titolo", ""))) >= 12}
    checkpoint = archivio.leggi("checkpoint")
    run = {"id": ora, "iniziata": ora, "fonti": {}, "nuovi": [], "gia_in_biblioteca": 0, "gia_proposti": 0,
           "scartati_poco_pertinenti": 0}

    attive = reg_fonti.attive(registro)
    for f in attive:
        esito = {"stato": "ok", "trovati": 0, "nuovi": 0}
        try:
            f = {**f, "parole_chiave": registro.get("parole_chiave", [])}
            trovati = adattatori[f["adattatore"]](f, registro.get("ricerche", []), fetcher, ora,
                                                  checkpoint.get(f["id"]))
            esito["trovati"] = len(trovati)
            for c in trovati:
                nt = normalizza(c["titolo"])
                if c["titolo"] and (chiave_opera(c["titolo"], c["autore"]) in inventario
                                    or any(t in nt for t in titoli_inv)):
                    run["gia_in_biblioteca"] += 1
                    continue
                if c["id"] in candidati:
                    run["gia_proposti"] += 1
                    continue
                c["punteggio"] = rilevanza.punteggio(c, fonte_curata=f["adattatore"] == "pagina_link")
                if c["punteggio"] < rilevanza.SOGLIA:
                    run["scartati_poco_pertinenti"] += 1
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
    r.append(f"Già in biblioteca: {run['gia_in_biblioteca']} · già proposti: {run['gia_proposti']} · "
             f"scartati perché poco pertinenti: {run['scartati_poco_pertinenti']}")
    r.append("")
    if run["nuovi"]:
        ordinati = sorted(run["nuovi"], key=lambda i: -candidati[i].get("punteggio", 0))
        r.append(f"## Da approvare: i {min(MOSTRA, len(ordinati))} più pertinenti su {len(ordinati)} nuovi")
        r.append("Formato approvazione: `ID:VERSIONE`")
        for cid in ordinati[:MOSTRA]:
            x = candidati[cid]
            r.append(f"- `{cid}:{x['versione'][:12]}` {x['titolo'][:120]} — {x['autore'][:60] or 's.a.'} "
                     f"[{x['lingua'] or '?'}, {x['formato'] or '?'}] ({x['fonte_id']}, pertinenza {x.get('punteggio', 0)})")
        if len(ordinati) > MOSTRA:
            r.append(f"- … altri {len(ordinati) - MOSTRA} candidati in archivio, non mostrati")
    else:
        r.append("Nessun candidato nuovo questo mese.")
    return "\n".join(r)
