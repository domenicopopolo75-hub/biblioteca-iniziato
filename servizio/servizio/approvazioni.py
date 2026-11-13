"""Approvazioni verificate nel servizio (non nel pulsante dell'app). Il silenzio non approva."""
from __future__ import annotations

from .archivio import Archivio
from .modello import APPROVATO, IMPORTATO, PROPOSTO, RIFIUTATO, RINVIATO, versione_candidato


class ErroreApprovazione(Exception):
    pass


def _cambia(c: dict, stato: str, adesso: str, nota: str = "") -> None:
    c["stato"] = stato
    c["storia"].append({"stato": stato, "quando": adesso, **({"nota": nota} if nota else {})})


def approva(archivio: Archivio, candidato_id: str, versione: str, da: str, adesso: str) -> dict:
    """Approva UN candidato, per UNA versione precisa. Idempotente."""
    candidati = archivio.leggi("candidati")
    c = candidati.get(candidato_id)
    if not c:
        raise ErroreApprovazione(f"candidato sconosciuto: {candidato_id}")
    attuale = versione_candidato(c)
    if len(versione) < 12 or c["versione"] != attuale or not attuale.startswith(versione):
        raise ErroreApprovazione("la versione del candidato è cambiata: serve una nuova approvazione")
    if c["stato"] in (RIFIUTATO,):
        raise ErroreApprovazione("candidato rifiutato")
    versione = attuale  # il prefisso (≥12 caratteri) del rapporto si lega alla versione completa
    appr = archivio.leggi("approvazioni")
    aid = f"{candidato_id}:{versione[:12]}"
    if aid in appr and not appr[aid].get("revocata"):
        return appr[aid]  # doppio invio: nessun effetto in più
    appr[aid] = {"id": aid, "candidato_id": candidato_id, "versione": versione, "da": da, "quando": adesso,
                 "revocata": False}
    if c["stato"] in (PROPOSTO, RINVIATO):
        _cambia(c, APPROVATO, adesso)
    archivio.scrivi("approvazioni", appr)
    archivio.scrivi("candidati", candidati)
    return appr[aid]


def rifiuta(archivio: Archivio, candidato_id: str, adesso: str, rinvia: bool = False) -> None:
    candidati = archivio.leggi("candidati")
    c = candidati[candidato_id]
    if c["stato"] in (IMPORTATO,):
        raise ErroreApprovazione("già importato")
    appr = archivio.leggi("approvazioni")
    for a in appr.values():
        if a["candidato_id"] == candidato_id:
            a["revocata"] = True
    _cambia(c, RINVIATO if rinvia else RIFIUTATO, adesso)
    archivio.scrivi("approvazioni", appr)
    archivio.scrivi("candidati", candidati)


def aggiorna_candidato(archivio: Archivio, candidato_id: str, adesso: str, **campi) -> bool:
    """Modifica i dati del candidato (es. nuova edizione). Se cambia l'identità, le approvazioni decadono."""
    candidati = archivio.leggi("candidati")
    c = candidati[candidato_id]
    vecchia = c["versione"]
    c.update(campi)
    c["versione"] = versione_candidato(c)
    cambiata = c["versione"] != vecchia
    if cambiata:
        appr = archivio.leggi("approvazioni")
        for a in appr.values():
            if a["candidato_id"] == candidato_id and a["versione"] == vecchia:
                a["revocata"] = True
        if c["stato"] != IMPORTATO:
            _cambia(c, PROPOSTO, adesso, "contenuto o edizione cambiati: nuova approvazione richiesta")
        archivio.scrivi("approvazioni", appr)
    archivio.scrivi("candidati", candidati)
    return cambiata


def approvazione_valida(archivio: Archivio, candidato_id: str) -> dict | None:
    c = archivio.leggi("candidati").get(candidato_id)
    if not c:
        return None
    for a in archivio.leggi("approvazioni").values():
        if (a["candidato_id"] == candidato_id and not a.get("revocata")
                and a["versione"] == c["versione"] == versione_candidato(c)):
            return a
    return None
