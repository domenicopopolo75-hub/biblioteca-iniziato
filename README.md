# Biblioteca dell'Iniziato

App iPhone per **uso esclusivamente personale** di Domenico Popolo: importa libri (PDF, EPUB, testo),
li legge e li fa **ascoltare in italiano** anche a schermo bloccato, con traduzione allineata ai blocchi
dell'originale. Progetto Ecce Quam Bonum (dossier su Drive, §13.2).

Il repository contiene **solo codice**: nessun libro, PDF, appunto o dato personale. I testi restano
sul Drive del proprietario e sul telefono.

| Cartella | Contenuto |
|---|---|
| `ios/` | App SwiftUI (progetto generato con XcodeGen da `ios/project.yml`) e test |
| `pipeline/` | Motore testi Python: originale → pacchetto `.bibl.json` con ordine di lettura ricostruito |
| `docs/` | Contratto del pacchetto e documenti tecnici |
| `STATO_PROGETTO.md` | Stato per lotto, prove eseguite, limiti e istruzioni di ripresa |

Uso del motore testi:

```bash
cd pipeline && pip install pymupdf pytest && python -m pytest -q
python -m biblioteca_pipeline /percorso/libro.pdf --lang it --anteprima 20
```
