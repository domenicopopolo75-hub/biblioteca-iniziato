"""Pertinenza dei candidati: evita di sommergere il proprietario con centinaia di proposte.

Deterministica e gratuita (nessun consumo IA). I pesi sono parametri da tarare sull'uso reale."""
from __future__ import annotations

from .modello import normalizza

FORTI = ("hermetic", "freemason", "masonic", "kabbal", "cabala", "theosoph", "rosicruc", "gnostic",
         "alchem", "martinis", "tarot", "thelema", "esoteric", "ermetic", "massone", "massonic", "iniziatic")
DEBOLI = ("occult", "mystic", "initiation", "symbolism", "magic")
# Autori già nei fili del dossier (Crowley, Steiner, Reghini, Kremmerz, Blavatsky, Mackey, ...)
AUTORI = ("crowley", "steiner", "reghini", "kremmerz", "blavatsky", "mackey", "pike", "waite", "mathers", "ragon",
          "wilmshurst", "levi", "papus", "martinez", "agrippa", "paracelsus", "fludd", "bohme",
          "eckartshausen", "guenon", "evola", "besant", "leadbeater", "preston", "kingsford",
          "maitland", "mead", "valli")  # cognomi non ambigui; Oliver, Ward, Street, Tucker... passano dalle parole chiave
SOGLIA = 3


def _cognome(autore: str) -> str:
    """«Cognome, Nome» (Gutenberg) oppure «Nome Cognome» (Internet Archive)."""
    a = autore.strip()
    if "," in a:
        return normalizza(a.split(",")[0])
    parole = normalizza(a).split()
    return parole[-1] if parole else ""


def punteggio(c: dict, fonte_curata: bool = False) -> int:
    testo = normalizza(" ".join((c.get("titolo", ""), c.get("argomenti", ""))))
    p = 3 if any(k in testo for k in FORTI) else 0
    p += 1 if any(k in testo for k in DEBOLI) else 0
    if any(_cognome(a) in AUTORI for a in (c.get("autore") or "").split(";")):
        p += 5
    if fonte_curata:
        p += 3  # elenchi scelti a mano dal proprietario/dossier
    return p
