import XCTest
@testable import MacCleaner

/// Las filas que se recuperan ejecutando una herramienta se salen del modelo
/// del resto: no borramos nosotros, asi que ni la red de seguridad ni la cuenta
/// de lo liberado funcionan igual. Estos tests fijan las dos cosas.
final class ReclaimTests: XCTestCase {

    private var reclaimable: [Target] {
        Catalog.targets.filter { $0.reclaim != nil }
    }

    // MARK: - Catalogo

    /// Lista explicita, como la de las filas desplegables: lanzar un proceso
    /// ajeno tiene que ser una decision, no algo que se cuele en un patron.
    func testSoloEstasFilasEjecutanUnaHerramienta() {
        XCTAssertEqual(Set(reclaimable.map(\.id)), ["sim.devices", "docker.disk"])
    }

    /// Nunca es "seguro": lo que hace la herramienta no lo decidimos nosotros,
    /// y no hay Papelera de la que sacarlo despues.
    func testPedirseloaOtroSiempreEsCuidado() {
        for target in reclaimable {
            XCTAssertEqual(target.risk, .caution, target.id)
        }
    }

    /// La red de seguridad sigue valiendo: aunque borre simctl, la ruta que se
    /// le pasa se mide y se comprueba aqui.
    func testLasRutasSiguenCayendoDentroDelHome() {
        for target in reclaimable {
            for path in target.patterns.flatMap({ FileSystem.expand($0) }) {
                XCTAssertTrue(Engine.isSafe(path), path)
                XCTAssertFalse(FileSystem.isProtected(path), path)
            }
        }
    }

    // MARK: - Red de seguridad

    /// Una ruta de fuera del home no llega nunca a `simctl delete`.
    func testUnaRutaDeFueraDelHomeNoSeEjecuta() {
        let result = Engine.reclaim(.simulator, paths: ["/Library/Developer/CoreSimulator/Devices/X"])
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.failedBytes, 0)
        XCTAssertEqual(result.errors.count, 1)
    }

    /// En `Devices/` no todo es un dispositivo: `device_set.plist` es el
    /// registro de todos, y borrarlo dejaria a Xcode sin ninguno.
    func testElRegistroDeSimuladoresNoEsUnSimulador() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("devs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }

        let device = base.appendingPathComponent("11F9DFF1-3C7F-4830-8587-D41125F5373E")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try (["name": "iPhone 17 Pro"] as NSDictionary)
            .write(to: device.appendingPathComponent("device.plist"))
        let registry = base.appendingPathComponent("device_set.plist")
        try Data("x".utf8).write(to: registry)

        XCTAssertTrue(FileSystem.isSimulatorDevice(device.path))
        XCTAssertFalse(FileSystem.isSimulatorDevice(registry.path))

        let target = Target(id: "sim.devices",
                            group: .xcode, risk: .caution, scope: .item,
                            patterns: [base.path + "/*"],
                            expansion: .paths,
                            reclaim: .simulator,
                            naming: .simulator)
        XCTAssertEqual(target.resolvePaths(), [device.path])
    }

    // MARK: - Nombres de simulador

    func testElRuntimeSeLeeEnCorto() {
        XCTAssertEqual(
            FileSystem.simulatorRuntimeName("com.apple.CoreSimulator.SimRuntime.iOS-26-5"),
            "iOS 26.5")
        XCTAssertEqual(
            FileSystem.simulatorRuntimeName("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"),
            "watchOS 11.0")
        XCTAssertNil(FileSystem.simulatorRuntimeName("iOS"), "sin guiones no hay version")
    }

    func testUnSimuladorSeTitulaConSuNombreYSuSistema() throws {
        let folder = try makeDevice(name: "iPhone 17 Pro",
                                    runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        XCTAssertEqual(FileSystem.simulatorName(of: folder), "iPhone 17 Pro · iOS 26.5")
    }

    func testSinRuntimeSeQuedaConElNombre() throws {
        let folder = try makeDevice(name: "iPad Air", runtime: nil)
        XCTAssertEqual(FileSystem.simulatorName(of: folder), "iPad Air")
    }

    /// Sin `device.plist` la fila se queda con el UDID: feo, pero cierto.
    func testSinPlistNoSeInventaUnNombre() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        XCTAssertNil(FileSystem.simulatorName(of: folder))
    }

    private func makeDevice(name: String, runtime: String?) throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        var device: [String: Any] = ["name": name]
        if let runtime { device["runtime"] = runtime }
        try (device as NSDictionary)
            .write(to: folder.appendingPathComponent("device.plist"))
        return folder.path
    }
}

// MARK: - Ejecutar programas

final class ToolsTests: XCTestCase {

    func testSeEncuentraUnaHerramientaDelSistema() {
        XCTAssertEqual(Tools.locate("ls"), "/bin/ls")
    }

    func testLoQueNoExisteNoSeInventa() {
        XCTAssertNil(Tools.locate("esto-no-existe-en-ningun-mac"))
    }

    func testSeRecogeLaSalidaYElEstado() {
        let ok = Tools.run("/bin/echo", ["hola"])
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.firstLine, "hola")
    }

    /// El fallo tiene que llegar al informe, no perderse.
    func testUnFalloDevuelveEstadoDistintoDeCero() {
        let bad = Tools.run("/bin/sh", ["-c", "echo roto >&2; exit 3"])
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.status, 3)
        XCTAssertEqual(bad.firstLine, "roto", "stderr tambien cuenta")
    }

    func testUnEjecutableQueNoExisteNoRevienta() {
        let missing = Tools.run("/usr/bin/no-existe", [])
        XCTAssertFalse(missing.ok)
        XCTAssertFalse(missing.output.isEmpty)
    }
}
