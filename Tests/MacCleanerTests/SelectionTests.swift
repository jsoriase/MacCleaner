import XCTest
@testable import MacCleaner

@MainActor
final class SelectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Estado limpio: sin elecciones guardadas de ejecuciones anteriores.
        let store = UserDefaults.standard
        for key in store.dictionaryRepresentation().keys where key.hasPrefix("select.") {
            store.removeObject(forKey: key)
        }
        store.removeObject(forKey: "selectionSchema")
    }

    func testAlEmpezarNoHayNadaMarcado() {
        let engine = Engine()
        XCTAssertFalse(engine.anySelected)
        XCTAssertEqual(engine.selectedBytes, 0)
        XCTAssertTrue(engine.rows.allSatisfy { !$0.selected })
    }

    func testIgnoraYLimpiaLasMarcasDeVersionesAnteriores() {
        // Una instalacion vieja dejaba las filas premarcadas en preferencias.
        let store = UserDefaults.standard
        store.set(true, forKey: "select.xcode.deriveddata")
        store.set(1, forKey: "selectionSchema")

        let engine = Engine()

        XCTAssertFalse(engine.anySelected, "las marcas heredadas deben ignorarse")
        XCTAssertNil(store.object(forKey: "select.xcode.deriveddata"), "y borrarse")
        XCTAssertNil(store.object(forKey: "selectionSchema"))
    }

    // MARK: - Botones por nivel de riesgo

    func testMarcarUnRiesgoMarcaSoloEseRiesgo() {
        let engine = Engine()
        engine.toggleRisk(.safe)

        XCTAssertTrue(engine.allSelected(for: .safe))
        XCTAssertFalse(engine.allSelected(for: .rebuild))
        XCTAssertFalse(engine.allSelected(for: .caution))

        for row in engine.rows {
            XCTAssertEqual(row.selected, row.target.risk == .safe, row.id)
        }
    }

    func testVolverAPulsarDesmarca() {
        let engine = Engine()
        engine.toggleRisk(.caution)
        XCTAssertTrue(engine.allSelected(for: .caution))

        engine.toggleRisk(.caution)
        XCTAssertFalse(engine.anySelected)
    }

    func testLosNivelesSonAcumulables() {
        let engine = Engine()
        engine.toggleRisk(.safe)
        engine.toggleRisk(.rebuild)

        XCTAssertTrue(engine.allSelected(for: .safe))
        XCTAssertTrue(engine.allSelected(for: .rebuild))
        XCTAssertFalse(engine.allSelected(for: .caution))

        let esperadas = engine.rows.filter { $0.target.risk != .caution }.count
        XCTAssertEqual(engine.rows.filter(\.selected).count, esperadas)
    }

    func testDesmarcarTodoLoLimpia() {
        let engine = Engine()
        for risk in Risk.allCases { engine.toggleRisk(risk) }
        XCTAssertEqual(engine.rows.filter(\.selected).count, engine.rows.count)

        engine.clearSelection()
        XCTAssertFalse(engine.anySelected)
    }

    /// Deliberado: cada sesion arranca vacia para que borrar sea siempre
    /// una decision consciente, no algo heredado del dia anterior.
    func testLaSeleccionNoSobreviveAOtraSesion() {
        let engine = Engine()
        engine.toggleRisk(.safe)
        XCTAssertTrue(engine.anySelected)

        let nueva = Engine()
        XCTAssertFalse(nueva.anySelected)
    }

    /// La preferencia de la Papelera si es una preferencia de verdad y se guarda.
    func testLaOpcionDePapeleraSiSeRecuerda() {
        let engine = Engine()
        engine.useTrash = true
        engine.persistTrashPreference()
        defer {
            UserDefaults.standard.removeObject(forKey: "useTrash")
        }

        XCTAssertTrue(Engine().useTrash)
    }

    /// Los tres botones tienen que cubrir el catalogo entero: si alguna fila
    /// no cae en ningun nivel, quedaria inalcanzable desde la barra.
    func testLosTresNivelesCubrenTodoElCatalogo() {
        let engine = Engine()
        for risk in Risk.allCases { engine.toggleRisk(risk) }
        XCTAssertTrue(engine.rows.allSatisfy(\.selected))
    }
}
