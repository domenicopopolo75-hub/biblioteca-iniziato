import Foundation
import PDFKit
import Vision

/// Estrazione PDF sul telefono con ricostruzione dell'ordine di lettura.
/// Stesse regole di `pipeline/biblioteca_pipeline/pdf.py`; in più raggruppa le righe in blocchi
/// (PDFKit fornisce righe, non blocchi) e fa OCR con Vision sulle pagine senza testo.
struct EstrattorePDF {
    static let margine = 0.12
    static let sogliaRipetuti = 0.30
    static let tolleranzaCentro = 8.0

    struct Riga { var rect: CGRect; var testo: String }   // rect in coordinate "dall'alto"

    struct BloccoGrezzo {
        var pagina: Int
        var rect: CGRect
        var righe: [String]
        var altezzaRiga: Double
        var colonna = 0
        var testo: String { righe.joined(separator: "\n") }
    }

    var ocrAbilitato = true

    // MARK: righe → blocchi

    static func raggruppa(_ righe: [Riga], pagina: Int) -> [BloccoGrezzo] {
        let ordinate = righe.filter { !$0.testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        var blocchi: [BloccoGrezzo] = []
        for r in ordinate {
            let h = max(r.rect.height, 1)
            var migliore: (Int, Double)?
            for (i, b) in blocchi.enumerated() {
                let sovrapposizione = min(b.rect.maxX, r.rect.maxX) - max(b.rect.minX, r.rect.minX)
                let minimo = 0.3 * min(b.rect.width, r.rect.width)
                let distacco = r.rect.minY - b.rect.maxY
                let altezzaSimile = abs(b.altezzaRiga - h) <= 0.35 * h
                if sovrapposizione > minimo, distacco < 0.7 * h, distacco > -0.5 * h, altezzaSimile {
                    if migliore == nil || distacco < migliore!.1 { migliore = (i, distacco) }
                }
            }
            if let (i, _) = migliore {
                blocchi[i].rect = blocchi[i].rect.union(r.rect)
                blocchi[i].righe.append(r.testo)
            } else {
                blocchi.append(BloccoGrezzo(pagina: pagina, rect: r.rect, righe: [r.testo], altezzaRiga: h))
            }
        }
        return blocchi
    }

    // MARK: ordine di lettura (identico al Python)

    static func ordinaPagina(_ blocchi: [BloccoGrezzo], corpo: Double) -> [BloccoGrezzo] {
        guard !blocchi.isEmpty else { return [] }
        let x0 = blocchi.map(\.rect.minX).min()!, x1 = blocchi.map(\.rect.maxX).max()!
        let centro = (x0 + x1) / 2
        var fasce: [[BloccoGrezzo]] = []
        var corrente: [BloccoGrezzo] = []
        for var b in blocchi.sorted(by: { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }) {
            let largo = b.rect.minX < centro - tolleranzaCentro && b.rect.maxX > centro + tolleranzaCentro
            if largo {
                if !corrente.isEmpty { fasce.append(corrente); corrente = [] }
                b.colonna = 0
                fasce.append([b])
            } else {
                b.colonna = b.rect.midX < centro ? 1 : 2
                corrente.append(b)
            }
        }
        if !corrente.isEmpty { fasce.append(corrente) }
        return fasce.flatMap { ordinaFascia($0, corpo: corpo) }
    }

    static func ordinaFascia(_ f: [BloccoGrezzo], corpo: Double) -> [BloccoGrezzo] {
        let sx = f.filter { $0.colonna == 1 }, dx = f.filter { $0.colonna == 2 }
        var prima: [BloccoGrezzo] = []
        if !sx.isEmpty, !dx.isEmpty, corpo > 0 {
            let topSx = sx.map(\.rect.minY).min()!
            prima = dx.filter { $0.altezzaRiga >= corpo * 1.25 && $0.rect.maxY <= topSx + 2 }
        }
        let resto = f.filter { b in !prima.contains { $0.rect == b.rect } }
        return prima.sorted { $0.rect.minY < $1.rect.minY }
            + resto.sorted { ($0.colonna, $0.rect.minY, $0.rect.minX) < ($1.colonna, $1.rect.minY, $1.rect.minX) }
    }

    // MARK: lettura righe

    static func righeNative(_ pagina: PDFPage) -> [Riga] {
        let box = pagina.bounds(for: .mediaBox)
        guard let sel = pagina.selection(for: box) else { return [] }
        return sel.selectionsByLine().compactMap { linea in
            guard let s = linea.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let r = linea.bounds(for: pagina)
            let alto = CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
            return Riga(rect: alto, testo: s.trimmingCharacters(in: .newlines))
        }
    }

    static func righeOCR(_ pagina: PDFPage) -> [Riga] {
        let box = pagina.bounds(for: .mediaBox)
        let scala: CGFloat = 2.5
        let img = pagina.thumbnail(of: CGSize(width: box.width * scala, height: box.height * scala), for: .mediaBox)
        guard let cg = img.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["it-IT", "en-US", "fr-FR", "de-DE", "la"]
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return (req.results ?? []).compactMap { oss in
            guard let t = oss.topCandidates(1).first?.string else { return nil }
            let b = oss.boundingBox   // normalizzato, origine in basso
            let r = CGRect(x: b.minX * box.width, y: (1 - b.maxY) * box.height,
                           width: b.width * box.width, height: b.height * box.height)
            return Riga(rect: r, testo: t)
        }
    }

    // MARK: documento intero

    func estrai(url: URL, sha256: String, lingua: String?, titolo: String?) throws -> Pacchetto {
        guard let doc = PDFDocument(url: url) else { throw ErroreEstrazione.illeggibile(url.lastPathComponent) }
        var pagine: [[BloccoGrezzo]] = []
        var altezze: [Double] = []
        var ocrFatto: [Int] = []
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { pagine.append([]); altezze.append(1); continue }
            altezze.append(p.bounds(for: .mediaBox).height)
            var righe = Self.righeNative(p)
            if righe.isEmpty, ocrAbilitato {
                righe = Self.righeOCR(p)
                if !righe.isEmpty { ocrFatto.append(i) }
            }
            pagine.append(Self.raggruppa(righe, pagina: i))
        }
        // intestazioni / piè di pagina ripetuti
        var conta: [String: Int] = [:]
        for (blocchi, h) in zip(pagine, altezze) {
            var chiavi = Set<String>()
            for b in blocchi where Self.nelMargine(b.rect, h) { chiavi.insert(Normalizza.chiaveRipetizione(b.testo)) }
            for k in chiavi { conta[k, default: 0] += 1 }
        }
        let n = pagine.count
        let minimo = n >= 3 ? max(3, Int((Double(n) * Self.sogliaRipetuti).rounded(.up))) : n + 1
        let ripetuti = Set(conta.filter { $0.value >= minimo }.keys)

        let altezzeRighe = pagine.flatMap { $0.map(\.altezzaRiga) }.sorted()
        let corpo = altezzeRighe.isEmpty ? 0 : altezzeRighe[altezzeRighe.count / 2]

        var out: [Blocco] = []
        var vuote: [Int] = [], senzaTesto: [Int] = []
        var conTesto = 0, ordine = 0
        for (i, blocchi) in pagine.enumerated() {
            var stampata: String?
            var tenuti: [BloccoGrezzo] = []
            for b in blocchi {
                let marg = Self.nelMargine(b.rect, altezze[i])
                if marg && ripetuti.contains(Normalizza.chiaveRipetizione(b.testo)) {
                    stampata = stampata ?? Normalizza.numeroStampato(b.testo); continue
                }
                if marg, let num = Normalizza.numeroStampato(b.testo),
                   b.testo.trimmingCharacters(in: .whitespacesAndNewlines).count <= 4 {
                    stampata = stampata ?? num; continue
                }
                tenuti.append(b)
            }
            if tenuti.isEmpty {
                if doc.page(at: i)?.string?.isEmpty ?? true { senzaTesto.append(i) } else { vuote.append(i) }
                continue
            }
            conTesto += 1
            for (k, b) in Self.ordinaPagina(tenuti, corpo: corpo).enumerated() {
                let testo = Normalizza.testo(b.testo)
                guard !testo.isEmpty else { continue }
                let script = Normalizza.scriptDominante(testo)
                var tipo = "paragraph"
                if corpo > 0, b.altezzaRiga >= corpo * 1.25, script == nil { tipo = "heading" }
                else if corpo > 0, b.altezzaRiga <= corpo * 0.85 { tipo = "note" }
                out.append(Blocco(id: String(format: "p%04d-b%04d", i, k), order: ordine, kind: tipo,
                                  locator: Locator(page_index: i, printed_page: stampata, column: b.colonna,
                                                   bbox: [b.rect.minX, b.rect.minY, b.rect.maxX, b.rect.maxY].map { ($0 * 10).rounded() / 10 },
                                                   chapter: nil, href: nil),
                                  lang: script ?? lingua, text_raw: b.testo, text: testo))
                ordine += 1
            }
        }
        let attr = doc.documentAttributes
        return Pacchetto(
            generated_at: ISO8601DateFormatter().string(from: Date()),
            generator: .init(name: "ios", version: "0.1.0"),
            work: .init(title: titolo ?? (attr?[PDFDocumentAttribute.titleAttribute] as? String) ?? url.deletingPathExtension().lastPathComponent,
                        author: attr?[PDFDocumentAttribute.authorAttribute] as? String, language: lingua),
            edition: .init(id: "sha256:\(sha256)", source_file: url.lastPathComponent, source_sha256: sha256,
                           format: "pdf", provenance: nil, pages_total: n),
            coverage: .init(units_total: n, units_with_text: conTesto, units_empty: vuote,
                            units_need_ocr: senzaTesto, excluded_repeated: ripetuti.sorted(),
                            units_ocr: ocrFatto),
            blocks: out)
    }

    static func nelMargine(_ r: CGRect, _ h: Double) -> Bool {
        r.maxY <= h * margine || r.minY >= h * (1 - margine)
    }
}

enum ErroreEstrazione: LocalizedError {
    case illeggibile(String), formatoNonSupportato(String), epub(String)
    var errorDescription: String? {
        switch self {
        case .illeggibile(let f): return "Impossibile aprire \(f)."
        case .formatoNonSupportato(let e): return "Formato non supportato: \(e)."
        case .epub(let m): return "EPUB non valido: \(m)."
        }
    }
}
