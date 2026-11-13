"""Acquisizione: solo con approvazione valida, verificata di nuovo al momento del download.

Retry idempotenti: stesso lavoro, stesso hash, nessuna copia ripetuta su Drive."""
from __future__ import annotations

import hashlib
import io
import json
import re
import zipfile

from .approvazioni import ErroreApprovazione, _cambia, approvazione_valida
from .archivio import Archivio
from .modello import APPROVATO, ERRORE, IMPORTATO, IN_DOWNLOAD, VERIFICATO

MAX_TENTATIVI = 5


class ErroreAcquisizione(Exception):
    pass


def verifica_formato(dati: bytes, formato: str) -> str:
    """Controlla che il file sia davvero ciò che dichiara; restituisce l'estensione verificata."""
    f = (formato or "").lower()
    if dati[:5] == b"%PDF-" and (f in ("", "pdf")):
        if b"%%EOF" not in dati[-2048:]:
            raise ErroreAcquisizione("PDF incompleto (manca %%EOF)")
        return "pdf"
    if dati[:2] == b"PK" and f in ("", "epub"):
        try:
            with zipfile.ZipFile(io.BytesIO(dati)) as z:
                if z.read("mimetype").strip() != b"application/epub+zip":
                    raise ErroreAcquisizione("EPUB con mimetype non valido")
        except (zipfile.BadZipFile, KeyError) as e:
            raise ErroreAcquisizione(f"EPUB non apribile: {e}") from e
        return "epub"
    if f in ("txt", "html", "htm"):
        try:
            dati.decode("utf-8")
        except UnicodeDecodeError as e:
            raise ErroreAcquisizione("testo non UTF-8") from e
        return "txt" if f == "txt" else "html"
    raise ErroreAcquisizione(f"contenuto non corrispondente al formato dichiarato ({formato or 'sconosciuto'})")


def nome_file(c: dict, estensione: str) -> str:
    base = " - ".join(x for x in (c.get("autore") or "", c.get("titolo") or c["id"]) if x)
    base = re.sub(r"[\\/:*?\"<>|\n\r\t]+", " ", base).strip()[:150]
    return f"{base}.{estensione}"


def crea_lavoro(archivio: Archivio, candidato_id: str, adesso: str) -> dict:
    a = approvazione_valida(archivio, candidato_id)
    if not a:
        raise ErroreApprovazione("nessuna approvazione valida: download rifiutato")
    lavori = archivio.leggi("lavori")
    if a["id"] in lavori:
        return lavori[a["id"]]  # stesso candidato e stessa versione: lo stesso lavoro
    lavori[a["id"]] = {"id": a["id"], "candidato_id": candidato_id, "versione": a["versione"],
                       "stato": APPROVATO, "tentativi": 0, "creato": adesso, "errori": []}
    archivio.scrivi("lavori", lavori)
    return lavori[a["id"]]


def risolvi_archive(c: dict, fetcher) -> tuple[str, str]:
    """Internet Archive: sceglie il file PDF/EPUB tra i metadati dell'elemento (solo dopo l'approvazione)."""
    ident = c["url_scheda"].rstrip("/").rsplit("/", 1)[-1]
    meta = json.loads(fetcher.get_testo(f"https://archive.org/metadata/{ident}"))
    files = [f for f in meta.get("files", []) if f.get("source") == "original"]
    for ext in ("epub", "pdf"):
        cand = sorted((f for f in files if f["name"].lower().endswith("." + ext)),
                      key=lambda f: int(f.get("size", 0)), reverse=True)
        if cand:
            return f"https://archive.org/download/{ident}/{cand[0]['name']}", ext
    raise ErroreAcquisizione("nessun PDF/EPUB originale scaricabile")


def esegui_lavoro(archivio: Archivio, lavoro_id: str, fetcher, sink, adesso: str) -> dict:
    lavori = archivio.leggi("lavori")
    j = lavori[lavoro_id]
    if j["stato"] == IMPORTATO:
        return j  # retry dopo il successo: nessuna azione
    if j["tentativi"] >= MAX_TENTATIVI:
        raise ErroreAcquisizione("troppi tentativi")
    # Verifica server: l'approvazione deve essere valida ADESSO e per QUESTA versione
    a = approvazione_valida(archivio, j["candidato_id"])
    if not a or a["versione"] != j["versione"]:
        j["stato"], j["errori"] = ERRORE, j["errori"] + ["approvazione non più valida"]
        archivio.scrivi("lavori", lavori)
        raise ErroreApprovazione("approvazione non più valida: download annullato")

    candidati = archivio.leggi("candidati")
    c = candidati[j["candidato_id"]]
    j["stato"], j["tentativi"] = IN_DOWNLOAD, j["tentativi"] + 1
    _cambia(c, IN_DOWNLOAD, adesso)
    archivio.scrivi("lavori", lavori)
    archivio.scrivi("candidati", candidati)
    try:
        url, fmt = c["url_download"], c["formato"]
        if not url:
            url, fmt = risolvi_archive(c, fetcher)
        dati = fetcher.get(url)
        ext = verifica_formato(dati, fmt)
        sha = hashlib.sha256(dati).hexdigest()
        j["sha256"], j["url_effettivo"] = sha, url
        hashes = archivio.leggi("hash_importati")
        if sha in hashes:
            j["drive_id"], j["duplicato_di"] = hashes[sha], sha  # stesso contenuto già in biblioteca
        else:
            j["drive_id"] = sink.carica(nome_file(c, ext), dati, chiave=f"{c['id']}:{sha[:16]}", formato=ext)
            hashes[sha] = j["drive_id"]
            archivio.scrivi("hash_importati", hashes)
        j["stato"], j["importato"] = IMPORTATO, adesso
        j["provenienza"] = {"fonte": c["fonte_id"], "scheda": c["url_scheda"], "download": url}
        _cambia(c, VERIFICATO, adesso)
        _cambia(c, IMPORTATO, adesso)
    except Exception as e:  # noqa: BLE001
        j["stato"] = ERRORE
        j["errori"].append(f"{type(e).__name__}: {e}"[:300])
        _cambia(c, ERRORE, adesso, str(e)[:200])
        archivio.scrivi("lavori", lavori)
        archivio.scrivi("candidati", candidati)
        raise
    archivio.scrivi("lavori", lavori)
    archivio.scrivi("candidati", candidati)
    return j
