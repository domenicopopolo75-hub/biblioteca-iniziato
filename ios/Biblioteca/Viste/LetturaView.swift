import PDFKit
import SwiftUI

/// Lettura: italiano per impostazione predefinita, originale con un tocco, pagina PDF originale raggiungibile.
struct LetturaView: View {
    @EnvironmentObject var libreria: Libreria
    @EnvironmentObject var lettore: Lettore
    @EnvironmentObject var traduttore: TraduttoreApple
    @EnvironmentObject var impostazioni: Impostazioni
    let libro: Libro
    var daOrdine = 0

    @State private var tradotti: [String: String] = [:]
    @State private var originale: Set<String> = []
    @State private var paginaPDF: Int?
    @State private var errore: String?
    @State private var limite = 60

    var body: some View {
        let blocchi = libreria.pacchetto(libro.id)?.blocks ?? []
        let formato = libreria.pacchetto(libro.id)?.edition.format ?? libro.formato
        List {
            if let e = errore { Text(e).foregroundStyle(.orange) }
            ForEach(finestra(blocchi)) { b in
                VStack(alignment: .leading, spacing: 6) {
                    let mostraOriginale = originale.contains(b.id) || !daTradurre(b)
                    Text(mostraOriginale ? b.text : (tradotti[b.id] ?? "…"))
                        .font(b.eTitolo ? .title3.bold() : (b.eNota ? .footnote : .body))
                        .foregroundStyle(b.eNota ? .secondary : .primary)
                        .textSelection(.enabled)
                    HStack {
                        Text(b.locator.descrizione(formato: formato)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if daTradurre(b) {
                            Button(originale.contains(b.id) ? "Italiano" : "Originale") {
                                if originale.contains(b.id) { originale.remove(b.id) } else { originale.insert(b.id) }
                            }.font(.caption).buttonStyle(.borderless)
                        }
                        if formato == "pdf" {
                            Button { paginaPDF = b.locator.page_index } label: { Image(systemName: "doc.richtext") }
                                .buttonStyle(.borderless)
                        }
                        Button { lettore.ascolta(libro, da: b.order) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                .background(b.order == daOrdine && daOrdine > 0 ? Color.yellow.opacity(0.15) : Color.clear)
                .task { if b.order >= inizio + limite - 5 { limite += 60 } }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Lettura")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: limite) { await traduciVisibili(finestra(blocchi)[...]) }
        .sheet(item: Binding(get: { paginaPDF.map(PaginaID.init) }, set: { paginaPDF = $0?.id })) { p in
            NavigationStack {
                PDFOriginale(url: libreria.originale(libro), pagina: p.id)
                    .navigationTitle("Originale, pag. PDF \(p.id + 1)")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    struct PaginaID: Identifiable { let id: Int }

    var inizio: Int { max(0, daOrdine - 3) }
    func finestra(_ b: [Blocco]) -> [Blocco] {
        guard inizio < b.count else { return [] }
        return Array(b[inizio..<min(b.count, inizio + limite)])
    }

    func daTradurre(_ b: Blocco) -> Bool {
        let l = String((b.lang ?? libro.lingua ?? "it").prefix(2))
        return l != "it" && l != "he" && l != "el"
    }

    func traduciVisibili(_ blocchi: ArraySlice<Blocco>) async {
        let arch = ArchivioTraduzioni(cartella: libreria.cartella(libro.id))
        var mancanti: [Blocco] = []
        for b in blocchi where daTradurre(b) && tradotti[b.id] == nil {
            if let v = await arch.voce(b) { tradotti[b.id] = v.testo } else { mancanti.append(b) }
        }
        let motore: MotoreTraduzione = impostazioni.usaAPI && ClienteClaude.chiavePresente ? MotoreClaude() : MotoreApple(traduttore: traduttore)
        let perLingua = Dictionary(grouping: mancanti) { String(($0.lang ?? libro.lingua ?? "en").prefix(2)) }
        for (lingua, gruppo) in perLingua {
            for inizio in stride(from: 0, to: gruppo.count, by: 8) {
                let lotto = Array(gruppo[inizio..<min(inizio + 8, gruppo.count)])
                do {
                    let t = try await motore.traduci(lotto.map(\.text), da: lingua)
                    for (b, s) in zip(lotto, t) {
                        tradotti[b.id] = s
                        await arch.registra(VoceTraduzione(testo: s, motore: motore.nome, versione: motore.versione, data: Date(),
                                                           linguaSorgente: lingua, hashSorgente: ArchivioTraduzioni.hash(b.text)), per: b.id)
                    }
                    await arch.salva()
                } catch {
                    errore = "Traduzione non disponibile: \(error.localizedDescription) Il testo originale resta consultabile."
                    return
                }
            }
        }
    }
}

struct PDFOriginale: UIViewRepresentable {
    let url: URL
    let pagina: Int
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        if let p = v.document?.page(at: pagina) { v.go(to: p) }
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}
