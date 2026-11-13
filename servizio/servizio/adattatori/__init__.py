"""Adattatori delle fonti: ognuno restituisce candidati (solo metadati, nessun libro scaricato)."""
from . import archive, gutenberg_csv, pagina_link

ADATTATORI = {"gutenberg_csv": gutenberg_csv.cerca, "archive": archive.cerca, "pagina_link": pagina_link.cerca}
