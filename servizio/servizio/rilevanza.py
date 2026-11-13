"""Pertinenza dei candidati: evita di sommergere il proprietario con centinaia di proposte.

Deterministica e gratuita (nessun consumo IA). I pesi sono parametri da tarare sull'uso reale."""
from __future__ import annotations

from .modello import normalizza

FORTI = ("hermetic", "freemason", "masonic", "kabbal", "cabala", "theosoph", "rosicruc", "gnostic",
         "alchem", "martinis", "tarot", "thelema", "esoteric", "ermetic", "massone", "massonic", "iniziatic")
DEBOLI = ("occult", "mystic", "initiation", "symbolism", "magic")
# Autori già nei fili del dossier (Crowley, Steiner, Reghini, Kremmerz, Blavatsky, Mackey, ...)
AUTORI = ("crowley", "steiner", "reghini", "kremmerz", "blavatsky", "mackey", "pike", "waite", "mathers", "ragon",
          "wilmshurst", "levi", "papus", "martinez", "saint martin", "agrippa", "paracelsus", "fludd", "bohme",
          "eckartshausen", "guenon", "evola", "besant", "leadbeater", "oliver", "preston", "newton", "kingsford",
          "maitland", "mead", "scott", "valli", "ward", "street", "tucker")
SOGLIA = 3


def punteggio(c: dict, fonte_curata: bool = False) -> int:
    testo = normalizza(" ".join((c.get("titolo", ""), c.get("argomenti", ""))))
    p = 3 if any(k in testo for k in FORTI) else 0
    p += 1 if any(k in testo for k in DEBOLI) else 0
    aut = normalizza(c.get("autore", ""))
    if any(a in aut.split() or f" {a} " in f" {aut} " for a in AUTORI):
        p += 5
    if fonte_curata:
        p += 3  # elenchi scelti a mano dal proprietario/dossier
    return p
