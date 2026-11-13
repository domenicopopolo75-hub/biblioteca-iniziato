"""Normalizzazione del testo estratto: legature, a-capo con trattino, spazi.

Il testo grezzo resta conservato nel pacchetto (`text_raw`); qui si produce solo `text`.
"""
from __future__ import annotations

import re
import unicodedata

# Legature tipografiche e caratteri di compatibilità più comuni nei PDF.
_LEGATURE = {
    "ﬀ": "ff", "ﬁ": "fi", "ﬂ": "fl", "ﬃ": "ffi", "ﬄ": "ffl",
    "ﬅ": "st", "ﬆ": "st", "­": "",  # trattino morbido
}
_SPAZI = re.compile(r"[ \t   ]+")
# parola-<a capo>parola  → parolaparola (solo se a capo c'è una minuscola: evita "Nord-\nEst")
_TRATTINO_A_CAPO = re.compile(r"(\w)[-‐‑]\n(?=[a-zà-öø-ÿ])")


def normalizza(testo: str) -> str:
    for k, v in _LEGATURE.items():
        testo = testo.replace(k, v)
    testo = unicodedata.normalize("NFC", testo)
    testo = testo.replace("\r\n", "\n").replace("\r", "\n")
    testo = _TRATTINO_A_CAPO.sub(r"\1", testo)
    # Le righe dentro un blocco diventano un unico paragrafo.
    righe = [r.strip() for r in testo.split("\n")]
    testo = " ".join(r for r in righe if r)
    testo = _SPAZI.sub(" ", testo).strip()
    return testo


def chiave_ripetizione(testo: str) -> str:
    """Chiave per riconoscere intestazioni/piè di pagina ripetuti: ignora numeri e spazi."""
    t = re.sub(r"\d+", "#", testo.lower())
    return re.sub(r"\s+", " ", t).strip()


def numero_stampato(testo: str) -> str | None:
    """Numero di pagina stampato se compare come riga isolata composta solo da cifre."""
    for riga in testo.splitlines():
        r = riga.strip()
        if re.fullmatch(r"\d{1,4}", r):
            return r
    return None


def script_dominante(testo: str) -> str | None:
    """'he' o 'el' se più della metà delle lettere è ebraica/greca; altrimenti None.
    Serve al lettore vocale per non leggere con voce italiana un versetto ebraico."""
    lettere = [c for c in testo if c.isalpha()]
    if not lettere:
        return None
    ebr = sum(1 for c in lettere if "\u0590" <= c <= "\u05ff")
    gre = sum(1 for c in lettere if "\u0370" <= c <= "\u03ff" or "\u1f00" <= c <= "\u1fff")
    if ebr * 2 > len(lettere):
        return "he"
    if gre * 2 > len(lettere):
        return "el"
    return None
