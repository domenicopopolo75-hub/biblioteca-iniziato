import AVFoundation
import SwiftUI

struct ImpostazioniView: View {
    @EnvironmentObject var impostazioni: Impostazioni
    @EnvironmentObject var drive: GoogleDrive
    @State private var chiave = ""
    @State private var budget = Budget.carica()
    @State private var chiavePresente = ClienteClaude.chiavePresente

    var body: some View {
        Form {
            Section {
                if chiavePresente {
                    LabeledContent("Chiave Claude", value: "salvata nel Portachiavi")
                    Button("Rimuovi chiave", role: .destructive) { Portachiavi.salva("", per: "anthropic"); chiavePresente = false }
                } else {
                    SecureField("Incolla la chiave API (sk-ant-…)", text: $chiave)
                    Button("Salva chiave") {
                        Portachiavi.salva(chiave.trimmingCharacters(in: .whitespacesAndNewlines), per: "anthropic")
                        chiave = ""; chiavePresente = ClienteClaude.chiavePresente
                    }.disabled(chiave.count < 20)
                }
                Stepper(value: $budget.euroMese, in: 1...50, step: 1) {
                    LabeledContent("Tetto mensile", value: String(format: "%.0f €", budget.euroMese))
                }
                .onChange(of: budget.euroMese) { var b = Budget.carica(); b.euroMese = budget.euroMese; b.salva() }
                LabeledContent("Speso a \(budget.mese)", value: String(format: "%.2f € su %.0f € (%d richieste)", budget.spesa, budget.euroMese, budget.chiamate))
                ForEach(budget.perFunzione.sorted(by: { $0.value > $1.value }), id: \.key) { f, v in
                    LabeledContent("  \(f)", value: String(format: "%.3f €", v)).font(.caption)
                }
            } header: { Text("Intelligenza artificiale (Claude)") } footer: {
                Text("Traduzioni e riassunti usano Claude Haiku 5.5 (pochi centesimi a libro); le domande e le analisi Claude Sonnet 5.5. Prima delle operazioni lunghe l'app mostra il costo; al tetto si ferma e lo dice. La chiave resta solo su questo iPhone.")
            }
            .onAppear { budget = Budget.carica(); chiavePresente = ClienteClaude.chiavePresente }

            Section("Traduzione") {
                Picker("Motore", selection: $impostazioni.usaAPI) {
                    Text("Claude Haiku (qualità, centesimi)").tag(true)
                    Text("Apple sul telefono (gratis)").tag(false)
                }
                .pickerStyle(.inline)
            }

            Section("Google Drive") {
                if drive.collegato {
                    LabeledContent("Stato", value: "collegato (sola lettura)")
                    Button("Scollega", role: .destructive) { drive.esci() }
                } else {
                    Button("Accedi con Google") { Task { await drive.accedi() } }
                }
            }

            Section("Voce italiana") {
                Picker("Voce", selection: $impostazioni.voce) {
                    Text("Migliore installata").tag("")
                    ForEach(SintetizzatoreFile.vociItaliane, id: \.identifier) { v in
                        Text("\(v.name) · \(qualita(v.quality))").tag(v.identifier)
                    }
                }
                Text("Voce migliore: Impostazioni iPhone › Accessibilità › Contenuto letto › Voci › Italiano › scarica una voce «Avanzata» o «Premium».")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Leggi le note", isOn: $impostazioni.leggiNote)
                Toggle("Annuncia i passi in ebraico/greco", isOn: $impostazioni.annunciaScritti)
                Stepper("Avvio dopo \(Int(impostazioni.avvioSecondi)) s di audio pronto", value: $impostazioni.avvioSecondi, in: 5...30, step: 1)
                Stepper("Riserva fino a \(Int(impostazioni.riservaSecondi)) s", value: $impostazioni.riservaSecondi, in: 30...300, step: 10)
            }

            Section("In arrivo") {
                Text("Fonti gratuite e ricerca mensile di nuovi testi, con la tua approvazione prima di ogni scaricamento su Drive.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Impostazioni")
    }

    func qualita(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q { case .premium: return "Premium"; case .enhanced: return "Avanzata"; default: return "Standard" }
    }
}
