"""Entità del flusso: Source, ScanRun, Candidate, Approval, AcquisitionJob (§13.1)."""
from __future__ import annotations

import hashlib
import re
import unicodedata

# Flusso persistente del candidato
PROPOSTO, APPROVATO, RIFIUTATO, RINVIATO = "proposto", "approvato", "rifiutato", "rinviato"
IN_DOWNLOAD, VERIFICATO, IMPORTATO, ERRORE = "in_download", "verificato", "importato", "errore"

# Campi che identificano il contenuto/edizione: se cambiano, l'approvazione decade.
CAMPI_IDENTITA = ("titolo", "autore", "anno", "lingua", "formato", "url_download")


def normalizza(testo: str) -> str:
    t = unicodedata.normalize("NFKD", testo or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def chiave_opera(titolo: str, autore: str) -> str:
    """Chiave di confronto con l'inventario: titolo normalizzato + cognome dell'autore."""
    cognome = normalizza((autore or "").split(",")[0]).split(" ")[0] if autore else ""
    return f"{normalizza(titolo)}|{cognome}"


def versione_candidato(c: dict) -> str:
    base = "\x1f".join(str(c.get(k) or "") for k in CAMPI_IDENTITA)
    return hashlib.sha256(base.encode()).hexdigest()


def id_candidato(fonte_id: str, riferimento: str) -> str:
    return hashlib.sha256(f"{fonte_id}\x1f{riferimento}".encode()).hexdigest()[:16]


def nuovo_candidato(fonte_id: str, riferimento: str, adesso: str, **campi) -> dict:
    c = {
        "id": id_candidato(fonte_id, riferimento),
        "fonte_id": fonte_id,
        "titolo": "", "autore": "", "anno": "", "lingua": "", "formato": "",
        "url_scheda": "", "url_download": "", "integrale": None, "dimensione": None,
        "motivo": "", "relazione": "", "verifica": "metadati", "visto": adesso,
        "stato": PROPOSTO, "storia": [{"stato": PROPOSTO, "quando": adesso}],
    }
    c.update(campi)
    c["versione"] = versione_candidato(c)
    return c
