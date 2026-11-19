import CryptoKit
import Foundation

/// Dove si trova un materiale. Tre cose diverse, mai mescolate nei risultati.
enum Origine: String, Codable, CaseIterable, Hashable {
    case telefono, drive, esterno

    var etichetta: String {
        switch self {
        case .telefono: return "Già sul telefono"
        case .drive: return "Su Google Drive"
        case .esterno: return "Fonte online"
        }
    }

    var icona: String {
        switch self {
        case .telefono: return "iphone"
        case .drive: return "externaldrive"
        case .esterno: return "globe"
        }
    }
}

/// Quanto del materiale l'app ha davvero visto. Il solo collegamento non è una lettura.
enum LivelloLettura: Int, Codable, Comparable, Hashable {
    case riferimento = 0   // trovato: scheda e collegamento, nessun testo visto
    case anteprima = 1     // visto solo un estratto breve (estratto di ricerca, descrizione)
    case parziale = 2      // testo recuperato ma incompleto (pagine senza testo, troncato)
    case completo = 3      // testo completo estratto ed elaborato dall'app

    static func < (a: LivelloLettura, b: LivelloLettura) -> Bool { a.rawValue < b.rawValue }

    var etichetta: String {
        switch self {
        case .riferimento: return "Solo riferimento"
        case .anteprima: return "Anteprima consultata"
        case .parziale: return "Testo parziale"
        case .completo: return "Testo completo elaborato"
        }
    }

    var spiegazione: String {
        switch self {
        case .riferimento: return "Esiste una scheda con il collegamento. Il testo non è stato letto."
        case .anteprima: return "È stato visto solo un estratto breve. Il libro non è stato letto."
        case .parziale: return "È stata elaborata solo una parte del testo (pagine senza testo o contenuto troncato)."
        case .completo: return "Tutto il testo disponibile è stato estratto ed elaborato dall'app."
        }
    }

    /// Livello raggiunto da un testo estratto: «completo» solo se ogni unità ha testo.
    static func per(pacchetto p: Pacchetto) -> LivelloLettura {
        if p.blocks.isEmpty { return .riferimento }
        let c = p.coverage
        if c.units_with_text >= c.units_total && c.units_need_ocr.isEmpty { return .completo }
        return .parziale
    }
}

enum StatoFonte: String, Codable, Hashable {
    case nonVerificata      // mai riconsultata dopo il salvataggio
    case verificata         // ultima consultazione coerente con la precedente
    case cambiata           // il contenuto è diverso da quello visto prima
    case nonRaggiungibile   // la fonte non risponde più o nega l'accesso

    var etichetta: String {
        switch self {
        case .nonVerificata: return "Non ancora riverificata"
        case .verificata: return "Fonte verificata"
        case .cambiata: return "Contenuto cambiato"
        case .nonRaggiungibile: return "Fonte non raggiungibile"
        }
    }
}

/// Scheda di un materiale: metadati e collegamento, mai il contenuto completo.
/// Resta dove sta il materiale (telefono, Drive, sito); la copia permanente è una scelta a parte.
struct Riferimento: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var titolo: String
    var titoloProvvisorio: Bool? = nil     // titolo ricavato dall'indirizzo, non dalla pagina
    var autore: String?
    var origine: Origine
    var nomeFonte: String
    var collegamento: String
    var lingua: String?
    var formato: String?
    var tipoMime: String? = nil
    var testoDisponibile: Bool?            // nil = non verificato
    var identificativoRemoto: String? = nil
    var versioneRemota: String? = nil
    var impronta: String? = nil            // sha256 del testo estratto all'ultima consultazione
    var salvatoIl: Date
    var ultimaConsultazione: Date? = nil
    var livello: LivelloLettura = .riferimento
    var stato: StatoFonte = .nonVerificata
    var notaStato: String? = nil
    var copiaId: String? = nil             // id del libro in biblioteca, se la copia è stata conservata

    /// Identità stabile: lo stesso materiale dà sempre lo stesso id, quindi salvarlo due volte non duplica.
    static func identita(origine: Origine, chiave: String) -> String {
        String(Impronta.sha256("\(origine.rawValue)|\(chiave)").prefix(24))
    }
}

/// Nota dell'utente ancorata a un passaggio, con provenienza e data di consultazione.
struct Appunto: Codable, Identifiable, Equatable {
    var id = UUID()
    var riferimentoId: String
    var passaggio: String        // es. «pag. PDF 12», «articolo»
    var bloccoId: String?
    var estratto: String         // al massimo 300 caratteri del passo
    var nota: String
    var consultatoIl: Date
    var impronta: String?        // versione del testo a cui si riferisce
    var creato = Date()
}

enum Impronta {
    static func sha256(_ s: String) -> String { sha256(Data(s.utf8)) }
    static func sha256(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
    /// Impronta del testo elaborato: stabile anche se cambiano elementi di contorno della pagina.
    static func testo(_ p: Pacchetto) -> String { sha256(p.blocks.map(\.text).joined(separator: "\n")) }
}

/// Un risultato di ricerca, con la provenienza sempre visibile.
struct Risultato: Identifiable, Hashable {
    enum Accesso: String, Hashable {
        case consultabile      // il contenuto è tecnicamente recuperabile e leggibile nell'app
        case soloCollegamento  // si può solo aprire la fonte
    }

    var id: String
    var titolo: String
    var titoloDaUrl = false
    var autore: String?
    var origine: Origine
    var nomeFonte: String
    var collegamento: String
    var lingua: String?
    var formato: String?
    var tipoMime: String? = nil
    var accesso: Accesso
    var identificativoRemoto: String? = nil
    var versioneRemota: String? = nil
    var anteprima: String? = nil
    var libroId: String? = nil      // libro già in biblioteca che corrisponde

    func comeRiferimento(adesso: Date = Date()) -> Riferimento {
        Riferimento(id: id, titolo: titolo, titoloProvvisorio: titoloDaUrl ? true : nil, autore: autore,
                    origine: origine, nomeFonte: nomeFonte, collegamento: collegamento, lingua: lingua,
                    formato: formato, tipoMime: tipoMime,
                    testoDisponibile: accesso == .consultabile ? nil : false,
                    identificativoRemoto: identificativoRemoto, versioneRemota: versioneRemota,
                    salvatoIl: adesso, livello: .riferimento)
    }
}

extension Riferimento {
    func comeRisultato() -> Risultato {
        Risultato(id: id, titolo: titolo, titoloDaUrl: titoloProvvisorio ?? false, autore: autore, origine: origine,
                  nomeFonte: nomeFonte, collegamento: collegamento, lingua: lingua, formato: formato, tipoMime: tipoMime,
                  accesso: testoDisponibile == false ? .soloCollegamento : .consultabile,
                  identificativoRemoto: identificativoRemoto, versioneRemota: versioneRemota)
    }
}
