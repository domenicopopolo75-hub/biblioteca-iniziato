# Formato del pacchetto testo (`.bibl.json`, versione 1)

Contratto unico tra il motore di estrazione (`pipeline/`, Python) e l'app iPhone (`ios/`).
L'originale (PDF/EPUB/TXT) resta immutabile: il pacchetto è un **derivato versionato** che lo cita per hash.

```json
{
  "format": "biblioteca-pacchetto/1",
  "generated_at": "2026-11-13T08:00:00Z",
  "generator": {"name": "pipeline", "version": "0.1.0"},
  "work":    {"title": "Ecce Quam Bonum n. 24", "author": "…", "language": "it"},
  "edition": {
    "id": "sha256:<hash originale>",
    "source_file": "EQB_24.pdf",
    "source_sha256": "<hash>",
    "format": "pdf | epub | txt",
    "provenance": "Drive / Ecce_Quam_Bonum_13-24.zip",
    "pages_total": 52
  },
  "coverage": {
    "units_total": 52, "units_with_text": 50,
    "units_empty": [0], "units_need_ocr": [51],
    "excluded_repeated": ["# ecce quam bonum marzo #"],
    "units_ocr": []
  },
  "blocks": [
    {
      "id": "p0003-b0002",
      "order": 17,
      "kind": "heading | paragraph | note",
      "locator": {"page_index": 3, "printed_page": "4", "column": 1,
                  "bbox": [56.7, 120.2, 290.1, 300.0], "chapter": "…", "href": null},
      "lang": "it",
      "text_raw": "testo come estratto",
      "text": "testo normalizzato (legature, a-capo con trattino, spazi)"
    }
  ]
}
```

Regole

- `order` è l'ordine di lettura del libro intero (colonne ricostruite). È l'unico ordine che il lettore vocale usa.
- `page_index` è la pagina **fisica** del PDF (da 0). `printed_page` solo se riconosciuto con certezza, altrimenti `null`.
- Per EPUB: `page_index` = indice del documento nello spine, `href` = file interno; nessuna pagina inventata.
- Intestazioni/piè di pagina ripetuti sono esclusi da `blocks` (restano consultabili nell'originale).
- `kind: note` = note a piè di pagina; il lettore può rimandarle con un comando esplicito.
- `units_need_ocr` = pagine ancora senza testo; `units_ocr` (solo app) = pagine il cui testo viene da OCR Vision.
- `excluded_repeated` = chiavi delle intestazioni/piè di pagina tolti (numeri sostituiti da `#`), per controllo.
- `lang` di un blocco vale `he`/`el` quando la maggioranza delle lettere è ebraica/greca: il lettore vocale lo annuncia invece di leggerlo con voce italiana.
- Le traduzioni NON stanno qui: sono derivati separati, per blocco, con lingua, motore e versione (`translations/<edition>/<lang>.json`).
