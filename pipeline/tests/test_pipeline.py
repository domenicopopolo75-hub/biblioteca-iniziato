"""Test su fixture generate al volo (nessun libro reale nel repository)."""
from __future__ import annotations

import json
import zipfile

import pymupdf
import pytest

from biblioteca_pipeline.normalizza import normalizza, script_dominante
from biblioteca_pipeline.pacchetto import crea_pacchetto, scrivi

SX = ["Sinistra uno: primo paragrafo della colonna sinistra.",
      "Sinistra due: secondo paragrafo della colonna sinistra.",
      "Sinistra tre: ultimo paragrafo della colonna sinistra."]
DX = ["Destra uno: primo paragrafo della colonna destra.",
      "Destra due: ultimo paragrafo della colonna destra."]


def _pdf_due_colonne(percorso, pagine=4, immagine_vuota=False):
    doc = pymupdf.open()
    for n in range(pagine):
        p = doc.new_page(width=595, height=842)
        p.insert_text((200, 40), "Rivista di prova", fontsize=10)          # intestazione ripetuta
        p.insert_text((290, 50), str(n + 1), fontsize=10)                   # numero stampato
        p.insert_textbox(pymupdf.Rect(40, 80, 555, 130), f"Titolo largo pagina {n + 1}", fontsize=20)
        p.insert_text((40, 820), "Ordine di prova", fontsize=8)              # piè di pagina ripetuto
        # La colonna destra viene scritta PRIMA nel flusso del PDF: l'ordine deve ricostruirsi da geometria.
        y = 150
        for t in DX:
            p.insert_textbox(pymupdf.Rect(310, y, 555, y + 80), t, fontsize=11)
            y += 100
        y = 150
        for t in SX:
            p.insert_textbox(pymupdf.Rect(40, y, 285, y + 80), t, fontsize=11)
            y += 100
    if immagine_vuota:
        p = doc.new_page(width=595, height=842)
        pix = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 20, 20), False)
        pix.clear_with(200)
        p.insert_image(pymupdf.Rect(100, 100, 300, 300), pixmap=pix)
        doc.new_page(width=595, height=842)
    doc.save(percorso)


def test_pdf_ordine_colonne_e_margini(tmp_path):
    f = tmp_path / "colonne.pdf"
    _pdf_due_colonne(str(f))
    p = crea_pacchetto(str(f), language="it")
    testi = [b["text"] for b in p["blocks"] if b["locator"]["page_index"] == 0]
    assert testi == ["Titolo largo pagina 1"] + SX + DX
    assert not any("Rivista di prova" in b["text"] or "Ordine di prova" in b["text"] for b in p["blocks"])
    assert {b["locator"]["printed_page"] for b in p["blocks"] if b["locator"]["page_index"] == 2} == {"3"}
    assert [b["order"] for b in p["blocks"]] == list(range(len(p["blocks"])))
    assert p["blocks"][0]["kind"] == "heading"
    assert p["edition"]["id"].startswith("sha256:") and p["edition"]["format"] == "pdf"


def test_pdf_copertura_ocr_e_vuote(tmp_path):
    f = tmp_path / "ocr.pdf"
    _pdf_due_colonne(str(f), pagine=3, immagine_vuota=True)
    c = crea_pacchetto(str(f))["coverage"]
    assert c["units_total"] == 5 and c["units_with_text"] == 3
    assert c["units_need_ocr"] == [3] and c["units_empty"] == [4]


def _epub(percorso):
    with zipfile.ZipFile(percorso, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
                   '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
                   '</rootfiles></container>')
        z.writestr("OEBPS/content.opf",
                   '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
                   '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test Book</dc:title>'
                   '<dc:creator>Anon</dc:creator><dc:language>en</dc:language></metadata>'
                   '<manifest><item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>'
                   '<item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/></manifest>'
                   '<spine><itemref idref="c2"/><itemref idref="c1"/></spine></package>')
        z.writestr("OEBPS/text/c1.xhtml",
                   '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head><body>'
                   '<h1>Chapter Two</h1><p>Second chapter text.</p>'
                   '<aside epub:type="footnote"><p>A footnote.</p></aside></body></html>')
        z.writestr("OEBPS/text/c2.xhtml",
                   '<html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter One</h1>'
                   '<p>First <i>chapter</i> text, with a hyphen-\nated word.</p><p>Equilibrium of oppo&#173;sites.</p></body></html>')


def test_epub_ordine_spine_capitoli_note(tmp_path):
    f = tmp_path / "libro.epub"
    _epub(str(f))
    p = crea_pacchetto(str(f))
    assert p["work"] == {"title": "Test Book", "author": "Anon", "language": "en"}
    testi = [(b["kind"], b["text"], b["locator"]["chapter"]) for b in p["blocks"]]
    assert testi[0] == ("heading", "Chapter One", "Chapter One")
    assert testi[1] == ("paragraph", "First chapter text, with a hyphenated word.", "Chapter One")
    assert testi[2][1] == "Equilibrium of opposites."
    assert testi[3][:2] == ("heading", "Chapter Two")
    assert testi[-1] == ("note", "A footnote.", "Chapter Two")
    assert all(b["locator"]["printed_page"] is None for b in p["blocks"])
    assert p["blocks"][0]["locator"]["href"] == "text/c2.xhtml"


def test_txt_italiano(tmp_path):
    f = tmp_path / "testo.txt"
    f.write_text("La pupilla del mondo\n\nPrimo paragrafo\nsu due righe.\n\nSecondo paragrafo.", encoding="utf-8")
    p = crea_pacchetto(str(f), language="it")
    assert [(b["kind"], b["text"]) for b in p["blocks"]] == [
        ("heading", "La pupilla del mondo"), ("paragraph", "Primo paragrafo su due righe."),
        ("paragraph", "Secondo paragrafo.")]
    assert all(b["lang"] == "it" for b in p["blocks"])


def test_pacchetto_json_roundtrip(tmp_path):
    f = tmp_path / "t.txt"
    f.write_text("Uno.\n\nDue.", encoding="utf-8")
    p = crea_pacchetto(str(f))
    out = tmp_path / "t.bibl.json"
    scrivi(p, str(out))
    assert json.loads(out.read_text(encoding="utf-8"))["format"] == "biblioteca-pacchetto/1"


@pytest.mark.parametrize("raw,atteso", [
    ("ﬁne e ﬂusso", "fine e flusso"),
    ("Nord-\nEst", "Nord- Est"),
    ("parola  con spazi", "parola con spazi"),
])
def test_normalizza(raw, atteso):
    assert normalizza(raw) == atteso


def test_script_dominante():
    assert script_dominante("כַּטַל־חֶרְמוֹן 3") == "he"
    assert script_dominante("λόγος") == "el"
    assert script_dominante("Logos") is None
