import hashlib
import io
import json
import zipfile
from datetime import datetime, timezone

import pytest

from servizio import acquisizione, approvazioni, calendario, fonti, scansione
from servizio.adattatori import pagina_link
from servizio.approvazioni import ErroreApprovazione
from servizio.archivio import Archivio, Occupato
from servizio.drive import DriveFinto
from servizio.modello import nuovo_candidato

ORA = "2026-12-01T07:00:00+01:00"


def pdf(testo=b"x"):
    return b"%PDF-1.4\n" + testo + b"\n%%EOF\n"


def epub():
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
    return b.getvalue()


class FetcherFinto:
    def __init__(self, risposte):
        self.risposte, self.richieste = risposte, []

    def get(self, url):
        self.richieste.append(url)
        v = self.risposte[url]
        if isinstance(v, Exception):
            raise v
        return v

    def get_testo(self, url):
        return self.get(url).decode()


@pytest.fixture
def arc(tmp_path):
    return Archivio(tmp_path / "dati")


def candidato(arc, ident="a", titolo="Kore Kosmou", url="https://x/a.pdf", fmt="pdf", **kw):
    c = nuovo_candidato("fonte", ident, ORA, titolo=titolo, autore="Anonimo", lingua="en", formato=fmt,
                        url_scheda="https://x/", url_download=url, **kw)
    cs = arc.leggi("candidati")
    cs[c["id"]] = c
    arc.scrivi("candidati", cs)
    return c


# ---------- calendario / scheduler ----------
def test_prossima_esecuzione_primo_del_mese_ore_7_roma():
    d = datetime(2026, 11, 13, 12, tzinfo=timezone.utc)
    p = calendario.prossima_esecuzione(d)
    assert (p.year, p.month, p.day, p.hour) == (2026, 12, 1, 7)
    assert p.utcoffset().total_seconds() == 3600  # CET
    p2 = calendario.prossima_esecuzione(datetime(2026, 12, 15, tzinfo=timezone.utc))
    assert (p2.year, p2.month) == (2027, 1)
    estate = calendario.prossima_esecuzione(datetime(2027, 4, 20, tzinfo=timezone.utc))
    assert estate.utcoffset().total_seconds() == 7200  # CEST: sempre 07:00 locali


def test_dovuta_simulazione_di_dodici_mesi_senza_aspettare():
    ultima, eseguite = None, 0
    t = datetime(2026, 11, 13, tzinfo=timezone.utc)
    for giorno in range(365):  # controllo giornaliero, come il cron
        adesso = t.replace(hour=12) + (datetime(2026, 11, 14) - datetime(2026, 11, 13)) * giorno
        if calendario.dovuta(adesso, ultima):
            ultima, eseguite = adesso, eseguite + 1
    assert eseguite == 13  # prima esecuzione subito + una per ogni primo del mese


def test_cron_saltato_viene_recuperato_il_giorno_dopo():
    ultima = datetime(2026, 11, 1, 8, tzinfo=timezone.utc)
    assert not calendario.dovuta(datetime(2026, 11, 20, tzinfo=timezone.utc), ultima)
    assert not calendario.dovuta(datetime(2026, 12, 1, 5, tzinfo=timezone.utc), ultima)  # prima delle 07:00 locali
    assert calendario.dovuta(datetime(2026, 12, 2, 5, tzinfo=timezone.utc), ultima)      # cron del 1 saltato


def test_blocco_impedisce_esecuzioni_sovrapposte_e_si_libera(arc):
    with arc.blocco():
        with pytest.raises(Occupato):
            with arc.blocco():
                pass
    with arc.blocco():
        pass


def test_blocco_abbandonato_viene_recuperato_dopo_riavvio(arc):
    import os
    p = arc.dir / "servizio.lock"
    p.write_text("999")
    vecchio = 1_000_000
    os.utime(p, (vecchio, vecchio))
    with arc.blocco():  # il processo precedente è morto: blocco scaduto
        pass


# ---------- scansione ----------
def registro():
    return {"ricerche": ["q"], "fonti": [
        {"id": "ok", "nome": "OK", "capacita": ["catalogo"], "adattatore": "ok", "stato": "attivo"},
        {"id": "rotta", "nome": "Rotta", "capacita": ["catalogo"], "adattatore": "rotta", "stato": "attivo"},
        {"id": "nessuna", "nome": "N", "capacita": ["catalogo"], "adattatore": None, "stato": "da_implementare"}]}


def adattatori():
    def ok(f, r, fe, ora, ult):
        return [nuovo_candidato("ok", "1", ora, titolo="Libro Uno", autore="Rossi, Mario", url_download="https://x/1.pdf", formato="pdf"),
                nuovo_candidato("ok", "2", ora, titolo="Già Posseduto", autore="Bianchi, Anna", url_download="https://x/2.pdf", formato="pdf")]

    def rotta(*a):
        raise RuntimeError("503 Service Unavailable")
    return {"ok": ok, "rotta": rotta}


def test_scansione_isola_la_fonte_guasta_e_non_si_dichiara_completa(arc):
    arc.scrivi("inventario", [{"titolo": "Già posseduto", "autore": "Bianchi, Anna"}])
    run = scansione.esegui_scansione(arc, registro(), None, datetime(2026, 12, 1, tzinfo=timezone.utc), adattatori())
    assert run["fonti"]["ok"]["stato"] == "ok" and run["fonti"]["rotta"]["stato"] == "fallita"
    assert len(run["nuovi"]) == 1 and run["gia_in_biblioteca"] == 1
    assert run["completa"] is False and run["copertura"]["controllate"] == 1
    cp = arc.leggi("checkpoint")
    assert "ok" in cp and "rotta" not in cp  # il checkpoint avanza solo per le fonti riuscite
    assert "parziale" in scansione.rapporto(run, arc.leggi("candidati"))


def test_scansione_ripetuta_non_riproduce_candidati_gia_proposti(arc):
    d = datetime(2026, 12, 1, tzinfo=timezone.utc)
    scansione.esegui_scansione(arc, registro(), None, d, adattatori())
    run2 = scansione.esegui_scansione(arc, registro(), None, d, adattatori())
    assert run2["nuovi"] == [] and run2["gia_proposti"] == 2
    assert len(arc.leggi("candidati")) == 2
    assert "Nessun candidato nuovo" in scansione.rapporto(run2, arc.leggi("candidati"))


def test_scansione_non_scarica_libri(arc):
    f = FetcherFinto({})
    scansione.esegui_scansione(arc, registro(), f, datetime(2026, 12, 1, tzinfo=timezone.utc), adattatori())
    assert f.richieste == []  # solo metadati: nessun file richiesto


def test_estrazione_link_pdf_epub():
    html = '<a href="/a/Libro%20Uno.pdf">Il Libro Uno</a><a href="b.epub"></a><a href="c.html">no</a>'
    r = pagina_link.estrai(html, "https://s.it/lista/")
    assert r[0] == ("https://s.it/a/Libro%20Uno.pdf", "Il Libro Uno")
    assert r[1][0] == "https://s.it/lista/b.epub" and r[1][1] == "b"
    assert len(r) == 2


def test_titoli_generici_ripuliti_con_contesto_o_nome_file():
    html = ('<h3>Rudolf Steiner: La filosofia della libertà</h3><a href="a/lib.pdf">Download del primo capitolo</a>'
            '<h3>Mackey</h3><a href="m/Symbolism_of_Freemasonry.pdf">Albert G. Mackey The Symbolism of Freemasonry (pdf)Download</a>'
            '<a href="x/Il_Libro_di_Prova.pdf">Scarica (301 Kb)</a>')
    t = [x[1] for x in pagina_link.estrai(html, "https://s.it/")]
    assert t[0].startswith("Rudolf Steiner: La filosofia della libertà") and "Download" not in t[0]
    assert t[1] == "Albert G. Mackey The Symbolism of Freemasonry"
    assert "Scarica" not in t[2] and "Kb" not in t[2]


def test_registro_reale_valido_e_copertura_dichiarata():
    reg = fonti.carica_registro()
    assert len(reg["fonti"]) == 17 and len(reg["servizi_personali"]) == 4
    cop = fonti.copertura(reg)
    assert cop["con_adattatore_attivo"] == len(fonti.attive(reg)) < 17
    assert "liberliber" in cop["da_implementare"]


# ---------- approvazioni: prove negative ----------
def test_nessun_download_senza_approvazione(arc):
    c = candidato(arc)
    with pytest.raises(ErroreApprovazione):
        acquisizione.crea_lavoro(arc, c["id"], ORA)
    f, sink = FetcherFinto({"https://x/a.pdf": pdf()}), DriveFinto()
    assert f.richieste == [] and sink.chiamate == 0


def test_silenzio_non_e_approvazione_e_stato_resta_proposto(arc):
    c = candidato(arc)
    assert arc.leggi("candidati")[c["id"]]["stato"] == "proposto"
    assert approvazioni.approvazione_valida(arc, c["id"]) is None


def test_approvazione_di_A_non_autorizza_B(arc):
    a = candidato(arc, "a", "Libro A", "https://x/a.pdf")
    b = candidato(arc, "b", "Libro B", "https://x/b.pdf")
    approvazioni.approva(arc, a["id"], a["versione"], "dom", ORA)
    assert approvazioni.approvazione_valida(arc, b["id"]) is None
    with pytest.raises(ErroreApprovazione):
        acquisizione.crea_lavoro(arc, b["id"], ORA)
    with pytest.raises(ErroreApprovazione):  # versione di A usata per B
        approvazioni.approva(arc, b["id"], a["versione"], "dom", ORA)


def test_candidato_modificato_invalida_l_autorizzazione(arc):
    c = candidato(arc)
    approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)
    j = acquisizione.crea_lavoro(arc, c["id"], ORA)
    assert approvazioni.aggiorna_candidato(arc, c["id"], ORA, url_download="https://x/altra-edizione.pdf") is True
    assert approvazioni.approvazione_valida(arc, c["id"]) is None
    assert arc.leggi("candidati")[c["id"]]["stato"] == "proposto"
    f, sink = FetcherFinto({"https://x/altra-edizione.pdf": pdf(), "https://x/a.pdf": pdf()}), DriveFinto()
    with pytest.raises(ErroreApprovazione):  # il lavoro già creato non parte più
        acquisizione.esegui_lavoro(arc, j["id"], f, sink, ORA)
    assert f.richieste == [] and sink.chiamate == 0
    with pytest.raises(ErroreApprovazione):  # la vecchia versione non si può più approvare
        approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)


def test_modifica_senza_cambio_di_identita_non_invalida(arc):
    c = candidato(arc)
    approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)
    assert approvazioni.aggiorna_candidato(arc, c["id"], ORA, motivo="nuovo motivo") is False
    assert approvazioni.approvazione_valida(arc, c["id"]) is not None


def test_rifiuto_revoca_e_blocca(arc):
    c = candidato(arc)
    approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)
    approvazioni.rifiuta(arc, c["id"], ORA)
    assert approvazioni.approvazione_valida(arc, c["id"]) is None
    with pytest.raises(ErroreApprovazione):
        approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)


def test_doppio_invio_dell_approvazione_e_idempotente(arc):
    c = candidato(arc)
    a1 = approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)
    a2 = approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)
    assert a1 == a2 and len(arc.leggi("approvazioni")) == 1


# ---------- acquisizione: idempotenza, verifica, hash ----------
def prepara(arc, dati=None, **kw):
    c = candidato(arc, **kw)
    approvazioni.approva(arc, c["id"], c["versione"], "dom", ORA)
    return c, acquisizione.crea_lavoro(arc, c["id"], ORA)


def test_import_completo_registra_hash_e_provenienza(arc):
    c, j = prepara(arc)
    d = pdf(b"contenuto")
    r = acquisizione.esegui_lavoro(arc, j["id"], FetcherFinto({"https://x/a.pdf": d}), sink := DriveFinto(), ORA)
    assert r["stato"] == "importato" and r["sha256"] == hashlib.sha256(d).hexdigest()
    assert r["provenienza"]["fonte"] == "fonte" and r["drive_id"].startswith("fake:")
    assert sink.chiamate == 1
    assert arc.leggi("candidati")[c["id"]]["stato"] == "importato"


def test_retry_dopo_successo_non_duplica(arc):
    c, j = prepara(arc)
    f, sink = FetcherFinto({"https://x/a.pdf": pdf()}), DriveFinto()
    acquisizione.esegui_lavoro(arc, j["id"], f, sink, ORA)
    acquisizione.esegui_lavoro(arc, j["id"], f, sink, ORA)
    j2 = acquisizione.crea_lavoro(arc, c["id"], ORA)  # doppio invio dell'ordine
    acquisizione.esegui_lavoro(arc, j2["id"], f, sink, ORA)
    assert len(sink.file) == 1 and sink.chiamate == 1 and len(f.richieste) == 1


def test_interruzione_dopo_upload_prima_del_registro_non_duplica(arc):
    """Il processo muore dopo il caricamento ma prima di salvare lo stato: il retry trova la stessa chiave."""
    c, j = prepara(arc)
    d, sink = pdf(b"z"), DriveFinto()
    sha = hashlib.sha256(d).hexdigest()
    sink.carica("n.pdf", d, chiave=f"{c['id']}:{sha[:16]}", formato="pdf")  # upload già avvenuto
    acquisizione.esegui_lavoro(arc, j["id"], FetcherFinto({"https://x/a.pdf": d}), sink, ORA)
    assert len(sink.file) == 1


def test_errore_di_rete_poi_retry_riesce_senza_copie(arc):
    c, j = prepara(arc)
    sink = DriveFinto()
    with pytest.raises(Exception):
        acquisizione.esegui_lavoro(arc, j["id"], FetcherFinto({"https://x/a.pdf": OSError("reset")}), sink, ORA)
    assert arc.leggi("lavori")[j["id"]]["stato"] == "errore" and sink.chiamate == 0
    acquisizione.esegui_lavoro(arc, j["id"], FetcherFinto({"https://x/a.pdf": pdf()}), sink, ORA)
    assert arc.leggi("lavori")[j["id"]]["stato"] == "importato" and len(sink.file) == 1


def test_download_incompleto_o_falso_rifiutato(arc):
    for corrotto in (b"%PDF-1.4\nmanca la fine", b"<html>403 Forbidden</html>", b""):
        a = Archivio(arc.dir / str(len(corrotto)))
        c, j = prepara(a)
        sink = DriveFinto()
        with pytest.raises(Exception):
            acquisizione.esegui_lavoro(a, j["id"], FetcherFinto({"https://x/a.pdf": corrotto}), sink, ORA)
        assert sink.chiamate == 0 and a.leggi("lavori")[j["id"]]["stato"] == "errore"


def test_epub_valido_accettato_e_non_confuso_con_pdf(arc):
    c, j = prepara(arc, ident="e", url="https://x/e.epub", fmt="epub")
    r = acquisizione.esegui_lavoro(arc, j["id"], FetcherFinto({"https://x/e.epub": epub()}), DriveFinto(), ORA)
    assert r["stato"] == "importato"
    with pytest.raises(acquisizione.ErroreAcquisizione):
        acquisizione.verifica_formato(epub(), "pdf")


def test_stesso_contenuto_da_altra_fonte_non_crea_secondo_file(arc):
    d, sink = pdf(b"stesso"), DriveFinto()
    c1, j1 = prepara(arc, ident="a", titolo="Libro", url="https://x/a.pdf")
    c2, j2 = prepara(arc, ident="b", titolo="Libro (copia)", url="https://y/b.pdf")
    f = FetcherFinto({"https://x/a.pdf": d, "https://y/b.pdf": d})
    r1 = acquisizione.esegui_lavoro(arc, j1["id"], f, sink, ORA)
    r2 = acquisizione.esegui_lavoro(arc, j2["id"], f, sink, ORA)
    assert len(sink.file) == 1 and r2["drive_id"] == r1["drive_id"] and "duplicato_di" in r2


def test_originali_non_sovrascritti_chiavi_distinte_per_contenuti_distinti(arc):
    c, j = prepara(arc)
    sink = DriveFinto()
    sink.carica("a.pdf", pdf(b"1"), "k1", "pdf")
    sink.carica("a.pdf", pdf(b"2"), "k2", "pdf")
    assert len(sink.file) == 2


def test_limite_tentativi(arc):
    c, j = prepara(arc)
    f = FetcherFinto({"https://x/a.pdf": OSError("giù")})
    for _ in range(acquisizione.MAX_TENTATIVI):
        with pytest.raises(OSError):
            acquisizione.esegui_lavoro(arc, j["id"], f, DriveFinto(), ORA)
    with pytest.raises(acquisizione.ErroreAcquisizione):
        acquisizione.esegui_lavoro(arc, j["id"], f, DriveFinto(), ORA)


def test_risoluzione_archive_sceglie_originale_pdf_o_epub():
    meta = {"files": [{"name": "x_text.pdf", "source": "derivative", "size": "999"},
                      {"name": "x.pdf", "source": "original", "size": "100"},
                      {"name": "x.epub", "source": "original", "size": "50"}]}
    f = FetcherFinto({"https://archive.org/metadata/xid": json.dumps(meta).encode()})
    url, ext = acquisizione.risolvi_archive({"url_scheda": "https://archive.org/details/xid"}, f)
    assert (url, ext) == ("https://archive.org/download/xid/x.epub", "epub")
