"""Adattatori delle fonti: ognuno restituisce candidati (solo metadati, nessun libro scaricato)."""
from . import archive, gutendex, pagina_link

ADATTATORI = {"gutendex": gutendex.cerca, "archive": archive.cerca, "pagina_link": pagina_link.cerca}
