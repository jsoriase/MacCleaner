import XCTest
@testable import MacCleaner

/// La logica de las filas desplegables vive entera en `Row`, asi que se puede
/// probar sin tocar el disco.
final class SubItemTests: XCTestCase {

    private func makeRow(_ items: [(String, Int64, Bool)],
                         selected: Bool = false,
                         expansion: Expansion = .children) -> Row {
        let target = Target(id: "gradle.caches",
                            group: .jvm, risk: .rebuild, scope: .contents,
                            patterns: ["~/.gradle/caches"], expansion: expansion)
        var row = Row(target: target, selected: selected)
        row.paths = [NSHomeDirectory() + "/.gradle/caches"]
        row.items = items.map { name, bytes, on in
            SubItem(path: NSHomeDirectory() + "/.gradle/caches/" + name,
                    name: name,
                    usage: FileSystem.Usage(bytes: bytes, files: 1),
                    selected: on)
        }
        return row
    }

    // MARK: - Estado de la casilla

    func testSinNadaMarcadoLaCasillaEstaVacia() {
        let row = makeRow([("9.1.0", 517, false), ("9.4.1", 766, false)])
        XCTAssertEqual(row.checkState, .off)
        XCTAssertFalse(row.anySelected)
    }

    func testConTodoMarcadoLaCasillaEstaLlena() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, true)])
        XCTAssertEqual(row.checkState, .on)
        XCTAssertTrue(row.anySelected)
    }

    func testConParteMarcadaLaCasillaQuedaAMedias() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, false)])
        XCTAssertEqual(row.checkState, .mixed)
        XCTAssertTrue(row.anySelected)
    }

    // MARK: - Tamano

    func testSoloCuentaElTamanoDeLoMarcado() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, false), ("modules-2", 748, false)])
        XCTAssertEqual(row.selectedBytes, 517, "solo la version marcada")
    }

    func testUnaFilaNormalCuentaSuTotalSiEstaMarcada() {
        var row = makeRow([], selected: true, expansion: .none)
        row.usage = FileSystem.Usage(bytes: 1234, files: 9)
        XCTAssertFalse(row.hasItems)
        XCTAssertEqual(row.selectedBytes, 1234)
    }

    // MARK: - Que se borra

    func testSeBorranSoloLasSubcarpetasMarcadas() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, false), ("modules-2", 748, true)])
        let (paths, scope) = row.victims

        XCTAssertEqual(scope, .item, "cada subcarpeta se borra entera")
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/9.1.0") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/modules-2") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/9.4.1") }, "la version sin marcar se queda")
    }

    func testUnaFilaNormalSigueBorrandoSuContenido() {
        var row = makeRow([], selected: true, expansion: .none)
        row.usage = FileSystem.Usage(bytes: 10, files: 1)
        let (paths, scope) = row.victims

        XCTAssertEqual(scope, .contents)
        XCTAssertEqual(paths, row.paths)
    }

    /// Las rutas de las subcarpetas tienen que pasar la red de seguridad,
    /// igual que las de las filas normales.
    func testLasSubcarpetasSonRutasSeguras() {
        let row = makeRow([("9.1.0", 517, true), ("modules-2", 748, true)])
        for path in row.victims.paths {
            XCTAssertTrue(Engine.isSafe(path), path)
            XCTAssertFalse(FileSystem.isProtected(path), path)
        }
    }

    // MARK: - Catalogo

    /// Lista explicita a proposito: desplegar una fila cambia lo que se borra,
    /// asi que anadir una tiene que ser una decision, no un descuido.
    func testSoloSeDesplieganLasFilasPrevistas() {
        let byChildren = Catalog.targets.filter { $0.expansion == .children }.map(\.id)
        XCTAssertEqual(Set(byChildren), ["gradle.caches", "gradle.wrapper",
                                         "xcode.deriveddata", "xcode.devicesupport",
                                         "xcode.archives", "ai.worktrees",
                                         "ai.vmbundles", "ai.models", "android.avd"])

        let byPaths = Catalog.targets.filter { $0.expansion == .paths }.map(\.id)
        XCTAssertEqual(Set(byPaths), ["jetbrains.caches", "jetbrains.logs", "caches.other",
                                      "electron.appsupport", "containers.caches",
                                      "sim.devices", "projects.deps", "projects.builds",
                                      "android.systemimages"])
    }

    func testLasFilasDesplegablesBorranPorContenido() {
        // Sus hijos son justo las victimas de un borrado .contents, asi que el
        // desglose y el borrado normal tienen que coincidir. Quedan fuera dos
        // casos: las filas que recupera una herramienta, donde no borramos
        // nosotros, y las de barrido, donde cada ruta encontrada es un
        // `node_modules` entero y vaciarlo no tendria sentido.
        for target in Catalog.targets
        where target.expandable && target.reclaim == nil && !target.isSweep {
            XCTAssertEqual(target.scope, .contents, target.id)
        }
    }

    /// Toda fila en modo .paths tiene que llevar comodin: sin el, el patron
    /// apunta a una sola carpeta y el desglose seria una fila con un solo hijo.
    func testLasFilasPorRutaExpandenUnComodin() {
        // Las de barrido no: sus rutas no salen de un comodin, sino de recorrer
        // las carpetas de codigo buscando por nombre.
        for target in Catalog.targets where target.expansion == .paths && !target.isSweep {
            XCTAssertTrue(target.patterns.allSatisfy { $0.contains("*") }, target.id)
        }
    }

    // MARK: - Modo .paths

    /// En .children el item es un hijo del target y se borra entero; en .paths
    /// el item es el target mismo, y vaciarlo no es lo mismo que borrarlo.
    func testEnModoPorRutaSeRespetaElScopeDelTarget() {
        let target = Target(id: "caches.other",
                            group: .system, risk: .caution, scope: .contents,
                            patterns: ["~/Library/Caches/*"],
                            isCatchAll: true, expansion: .paths)
        var row = Row(target: target, selected: false)
        let cache = NSHomeDirectory() + "/Library/Caches/com.ejemplo.app"
        row.paths = [cache]
        row.items = [SubItem(path: cache, name: "com.ejemplo.app",
                             usage: FileSystem.Usage(bytes: 900, files: 3), selected: true)]

        let (paths, scope) = row.victims
        XCTAssertEqual(scope, .contents, "la carpeta de la app se vacia, no se borra")
        XCTAssertEqual(paths, [cache])
    }

    // MARK: - Antiguedad

    private func item(daysAgo: Double) -> SubItem {
        let when = Date().addingTimeInterval(-daysAgo * 24 * 60 * 60)
        return SubItem(path: NSHomeDirectory() + "/.gradle/caches/9.1.0",
                       name: "9.1.0",
                       usage: FileSystem.Usage(bytes: 1, files: 1,
                                               newest: time_t(when.timeIntervalSince1970)))
    }

    func testUnaSubcarpetaSinTocarEnAnoYMedioSeMarcaComoVieja() {
        XCTAssertTrue(item(daysAgo: 540).isStale)
    }

    func testUnaSubcarpetaDeLaSemanaPasadaNoSeMarca() {
        XCTAssertFalse(item(daysAgo: 7).isStale)
    }

    func testSinFechaNoSeMarcaNada() {
        var blank = item(daysAgo: 540)
        blank.usage.newest = 0
        XCTAssertNil(blank.usage.modified)
        XCTAssertFalse(blank.isStale, "sin dato no se acusa a nadie de vieja")
    }
}

/// El nivel de riesgo dice cuanto cuidado hay que tener; la consecuencia dice
/// por que. Si las dos no cuadran, el distintivo miente al pasar el raton.
final class ConsequenceTests: XCTestCase {

    func testTodaFilaSeguraSeRehaceSola() {
        for target in Catalog.targets where target.risk == .safe {
            XCTAssertEqual(target.why, .regenerates, target.id)
        }
    }

    /// Al reves tambien: nada que se rehaga solo puede estar etiquetado de otra
    /// forma, o el boton de «Seguras» se estaria dejando filas fuera.
    func testSoloLasFilasSegurasSeRehacenSolas() {
        for target in Catalog.targets where target.why == .regenerates {
            XCTAssertEqual(target.risk, .safe, target.id)
        }
    }

    func testLoQueSeRegeneraNoSePierde() {
        let esperadas: Set<Consequence> = [.slowerBuild, .redownload]
        for target in Catalog.targets where target.risk == .rebuild {
            XCTAssertTrue(esperadas.contains(target.why),
                          "\(target.id) promete regenerarse y dice \(target.why.rawValue)")
        }
    }

    /// Una fila de «Cuidado» no puede consolar diciendo que solo tardara mas.
    func testCuidadoNuncaEsSoloUnaCompilacionMasLenta() {
        for target in Catalog.targets where target.risk == .caution {
            XCTAssertNotEqual(target.why, .slowerBuild, target.id)
            XCTAssertNotEqual(target.why, .regenerates, target.id)
        }
    }

    /// Si borra otro programa, hay que decirlo: es la unica consecuencia que no
    /// depende de lo que decidamos nosotros.
    func testSiBorraOtroProgramaLaFilaLoDice() {
        for target in Catalog.targets {
            XCTAssertEqual(target.reclaim != nil, target.why == .toolDecides, target.id)
        }
    }

    func testCadaConsecuenciaTieneTexto() {
        for why in [Consequence.regenerates, .slowerBuild, .redownload, .recreate,
                    .dataLoss, .signOut, .toolDecides, .unknown] {
            XCTAssertFalse(why.text.isEmpty, why.rawValue)
        }
    }
}
