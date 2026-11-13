from __future__ import annotations

import json
from importlib import resources

CAPACITA = {"catalogo", "testo_completo", "download", "collegamento"}


def carica_registro(percorso: str | None = None) -> dict:
    if percorso:
        with open(percorso, encoding="utf-8") as f:
            reg = json.load(f)
    else:
        reg = json.loads(resources.files("servizio").joinpath("fonti.json").read_text(encoding="utf-8"))
    ids = set()
    for f in reg["fonti"] + reg.get("servizi_personali", []):
        assert f["id"] not in ids, f"id duplicato: {f['id']}"
        ids.add(f["id"])
        assert set(f["capacita"]) <= CAPACITA, f
    return reg


def attive(reg: dict) -> list[dict]:
    return [f for f in reg["fonti"] if f.get("stato") == "attivo" and f.get("adattatore")]


def copertura(reg: dict) -> dict:
    tot = len(reg["fonti"])
    att = len(attive(reg))
    return {"fonti_registrate": tot, "con_adattatore_attivo": att,
            "da_implementare": [f["id"] for f in reg["fonti"] if f not in attive(reg)]}
