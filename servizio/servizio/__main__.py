"""Uso: python -m servizio <scansiona|approva|esegui|calendario> --dati DIR ..."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone

from . import acquisizione, approvazioni, calendario, fonti, scansione
from .archivio import Archivio, Occupato
from .rete import Fetcher


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="servizio")
    ap.add_argument("comando", choices=["scansiona", "approva", "esegui", "calendario"])
    ap.add_argument("--dati", default="dati")
    ap.add_argument("--forza", action="store_true", help="scansiona anche se non è dovuta")
    ap.add_argument("--id", action="append", default=[], help="candidato nel formato ID:VERSIONE (la versione che l'utente ha visto)")
    ap.add_argument("--da", default="proprietario")
    ap.add_argument("--rapporto", help="file in cui scrivere il rapporto")
    a = ap.parse_args(argv)
    adesso = datetime.now(timezone.utc)
    arc = Archivio(a.dati)

    if a.comando == "calendario":
        t = adesso
        for _ in range(14):
            t = calendario.prossima_esecuzione(t)
            print(t.isoformat())
        return 0

    try:
        with arc.blocco():
            if a.comando == "scansiona":
                reg = fonti.carica_registro()
                ultima = max((datetime.fromisoformat(e["iniziata"]) for e in arc.leggi("esecuzioni") if e.get("riuscita")),
                             default=None)
                if not a.forza and not calendario.dovuta(adesso, ultima):
                    print("scansione non dovuta")
                    return 0
                run = scansione.esegui_scansione(arc, reg, Fetcher(), adesso)
                testo = scansione.rapporto(run, arc.leggi("candidati"))
                if a.rapporto:
                    open(a.rapporto, "w", encoding="utf-8").write(testo)
                print(testo)
                print(f"::NUOVI={len(run['nuovi'])}", file=sys.stderr)
            elif a.comando == "approva":
                for voce in a.id:
                    cid, _, versione = voce.partition(":")
                    approvazioni.approva(arc, cid, versione, a.da, adesso.isoformat())
                    print("approvato", cid)
            elif a.comando == "esegui":
                from .drive import GoogleDrive
                sink, f = GoogleDrive(), Fetcher()
                for cid, c in arc.leggi("candidati").items():
                    if c["stato"] in ("approvato", "in_download", "errore") and approvazioni.approvazione_valida(arc, cid):
                        j = acquisizione.crea_lavoro(arc, cid, adesso.isoformat())
                        try:
                            r = acquisizione.esegui_lavoro(arc, j["id"], f, sink, adesso.isoformat())
                            print("importato", cid, r["drive_id"])
                        except Exception as e:  # noqa: BLE001
                            print("errore", cid, e, file=sys.stderr)
    except Occupato:
        print("un'altra esecuzione è in corso", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
