"""Calendario mensile: primo giorno del mese, ore 07:00 Europe/Rome (modificabile)."""
from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

ROMA = ZoneInfo("Europe/Rome")


def scadenza_del_mese(adesso: datetime, giorno: int = 1, ora: int = 7) -> datetime:
    a = adesso.astimezone(ROMA)
    return a.replace(day=giorno, hour=ora, minute=0, second=0, microsecond=0)


def prossima_esecuzione(dopo: datetime, giorno: int = 1, ora: int = 7) -> datetime:
    s = scadenza_del_mese(dopo, giorno, ora)
    if s > dopo.astimezone(ROMA):
        return s
    a = s
    anno, mese = (a.year + 1, 1) if a.month == 12 else (a.year, a.month + 1)
    return a.replace(year=anno, month=mese)


def dovuta(adesso: datetime, ultima_riuscita: datetime | None, giorno: int = 1, ora: int = 7) -> bool:
    """True se la scadenza di questo mese è passata e non c'è una scansione riuscita dopo di essa.

    Il controllo giornaliero rende l'esecuzione robusta a cron saltati o in ritardo."""
    s = scadenza_del_mese(adesso, giorno, ora)
    if adesso.astimezone(ROMA) < s:
        # prima della scadenza di questo mese: conta quella del mese scorso
        anno, mese = (s.year - 1, 12) if s.month == 1 else (s.year, s.month - 1)
        s = s.replace(year=anno, month=mese)
    return ultima_riuscita is None or ultima_riuscita.astimezone(ROMA) < s
