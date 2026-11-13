import XCTest

/// Percorre l'app in modalità dimostrativa e salva una schermata per ogni vista principale.
final class SchermateUITests: XCTestCase {
    let app = XCUIApplication()

    func scatta(_ nome: String) {
        sleep(1)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = nome
        a.lifetime = .keepAlways
        add(a)
    }

    func testPercorso() throws {
        continueAfterFailure = true
        app.launchArguments = ["-demo"]
        app.launch()

        let libro = app.staticTexts["Esempio - Equilibrio e Tempio"]
        XCTAssertTrue(libro.waitForExistence(timeout: 20))
        scatta("01-biblioteca-guida")

        app.buttons["importa"].tap()
        sleep(1)
        scatta("02-aggiungi-menu")
        if app.buttons["Da Google Drive"].waitForExistence(timeout: 3) {
            app.buttons["Da Google Drive"].tap()
            sleep(2)
            scatta("03-google-drive")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        libro.tap()
        sleep(1)
        scatta("04-libro-leggi-ascolta")
        app.swipeUp()
        scatta("05-libro-studia")
        app.swipeDown()

        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Leggi in italiano'")).firstMatch.tap()
        sleep(2)
        scatta("06-lettura")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["ascolta"].tap()
        sleep(10)
        scatta("07-ascolta")

        app.tabBars.buttons["Studio"].tap()
        let campo = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        campo.tap()
        campo.typeText("tempio")
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Cerca nei testi'")).firstMatch.tap()
        sleep(1)
        if app.keyboards.count > 0 { app.swipeDown() }
        scatta("08-studio-ricerca")

        app.tabBars.buttons["Impostazioni"].tap()
        sleep(1)
        scatta("09-impostazioni")
        app.swipeUp()
        scatta("10-impostazioni-voce")
    }
}
