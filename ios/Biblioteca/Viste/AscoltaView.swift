import AVFoundation
import SwiftUI

struct AscoltaView: View {
    @EnvironmentObject var lettore: Lettore

    var body: some View {
        List {
            if let l = lettore.libro {
                Section {
                    Text(l.titolo).font(.headline)
                    statoView
                    Text(lettore.testoCorrente.isEmpty ? "—" : lettore.testoCorrente)
                        .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("testoCorrente")
                }
                Section {
                    HStack(spacing: 36) {
                        Spacer()
                        Button { lettore.indietro() } label: { Image(systemName: "gobackward.15").font(.title) }
                        Button {
                            lettore.stato == .riproduzione ? lettore.pausa(causa: nil) : lettore.riprendi()
                        } label: {
                            Image(systemName: lettore.stato == .riproduzione ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 54))
                        }
                        .accessibilityIdentifier("playPausa")
                        Button { lettore.avanti() } label: { Image(systemName: "goforward.15").font(.title) }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    Picker("Velocità", selection: $lettore.velocita) {
                        Text("1×").tag(Float(1.0)); Text("1,25×").tag(Float(1.25)); Text("1,5×").tag(Float(1.5))
                    }.pickerStyle(.segmented)
                    Menu {
                        Button("15 minuti") { lettore.timer(minuti: 15) }
                        Button("30 minuti") { lettore.timer(minuti: 30) }
                        Button("60 minuti") { lettore.timer(minuti: 60) }
                        Button("Nessun timer") { lettore.timer(minuti: nil) }
                    } label: {
                        Label(lettore.fineTimer.map { "Timer fino alle \($0.formatted(date: .omitted, time: .shortened))" } ?? "Timer",
                              systemImage: "timer")
                    }
                    Button { lettore.segnalibro() } label: { Label("Segnalibro qui", systemImage: "bookmark") }
                }
                Section("Prova d'ascolto (misure)") { MetricheView(m: lettore.metriche, riserva: lettore.riserva) }
                if let u = lettore.esportaMetriche() {
                    ShareLink(item: u) { Label("Esporta misure (JSON)", systemImage: "square.and.arrow.up") }
                }
            } else {
                ContentUnavailableView("Niente in ascolto", systemImage: "headphones",
                                       description: Text("Apri un libro e scegli «Ascolta in italiano»."))
            }
        }
        .navigationTitle("Ascolta")
    }

    @ViewBuilder var statoView: some View {
        switch lettore.stato {
        case .fermo: Text("Fermo").foregroundStyle(.secondary)
        case .preparazione:
            if let p = lettore.preparazioneOffline {
                ProgressView(value: min(p.fatti, p.obiettivo), total: p.obiettivo) {
                    Text("Preparo per l'ascolto offline: \(Int(p.fatti / 60)) di \(Int(p.obiettivo / 60)) min")
                }
            } else { HStack { ProgressView(); Text("Preparo i primi secondi in italiano…") } }
        case .riproduzione: Text("In ascolto · riserva \(Int(lettore.riserva)) s").foregroundStyle(.green)
        case .pausa: Text("In pausa").foregroundStyle(.secondary)
        case .attesa(let m): Text(m).foregroundStyle(.orange)
        case .errore(let m): Text(m).foregroundStyle(.red)
        case .finito: Text("Libro terminato").foregroundStyle(.secondary)
        }
    }
}

struct MetricheView: View {
    let m: Metriche
    let riserva: Double
    func f(_ v: Double?) -> String { v.map { String(format: "%.1f s", $0) } ?? "—" }
    var body: some View {
        LabeledContent("Primo audio dopo", value: f(m.primoAudioSecondi))
        LabeledContent("Sintesi per segmento p50/p95/p99",
                       value: [0.5, 0.95, 0.99].map { f(Metriche.percentile(m.latenzeSintesi, $0)) }.joined(separator: " / "))
        LabeledContent("Traduzione per lotto p50/p95",
                       value: [0.5, 0.95].map { f(Metriche.percentile(m.latenzeTraduzione, $0)) }.joined(separator: " / "))
        LabeledContent("Produzione ÷ consumo", value: m.rapportoProduzione.map { String(format: "%.1f×", $0) } ?? "—")
        LabeledContent("Riserva ora / minima", value: "\(Int(riserva)) s / \(f(m.riservaMinima))")
        LabeledContent("Interruzioni", value: "\(m.interruzioni.count) (\(f(m.interruzioni.map(\.durata).reduce(0, +))))")
        LabeledContent("Ascoltato", value: "\(Int(m.secondiAscoltati / 60)) min")
        LabeledContent("Voce · traduzione", value: "\(m.voce) · \(m.motoreTraduzione)")
    }
}
