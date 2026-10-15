import XCTest
@testable import MacCleaner

// MARK: - Quien esta usando una ruta

/// Borrar la cache de un programa abierto rompe ese programa. Estos tests
/// fijan como se reconoce a cada uno sin depender de lo que tenga abierto la
/// maquina que los corre: los procesos y las apps se inventan.
final class OccupancyTests: XCTestCase {

    private let home = NSHomeDirectory()

    private func snapshot(apps: [ProcessSnapshot.App] = [],
                          processes: [[String]]? = [],
                          booted: Bool = false) -> ProcessSnapshot {
        ProcessSnapshot(apps: apps, processes: processes, bootedSimulator: booted)
    }

    // MARK: Nombre del programa

    func testUnBinarioSeLlamaComoSuEjecutable() {
        XCTAssertEqual(ProcessSnapshot.command(of: ["/usr/bin/xcodebuild", "-scheme", "App"]), "xcodebuild")
    }

    /// `npm` es un script de node: el proceso se llama node, pero es npm.
    func testUnScriptDeNodeSeLlamaComoElScript() {
        XCTAssertEqual(ProcessSnapshot.command(of: ["node", "/opt/homebrew/bin/npm", "install"]), "npm")
        XCTAssertEqual(ProcessSnapshot.command(
            of: ["/usr/local/bin/node", "/x/.cache/node/corepack/v1/pnpm/9.0.0/bin/pnpm.cjs", "i"]), "pnpm")
    }

    func testLasOpcionesDelInterpreteNoSonElScript() {
        XCTAssertEqual(ProcessSnapshot.command(
            of: ["node", "--max-old-space-size=4096", "/x/tsserver.js"]), "tsserver")
        XCTAssertEqual(ProcessSnapshot.command(of: ["python3", "-m", "pip"]), "pip")
    }

    func testUnInterpreteSinScriptSeQuedaComoInterprete() {
        XCTAssertEqual(ProcessSnapshot.command(of: ["node"]), "node")
        XCTAssertNil(ProcessSnapshot.command(of: []))
    }

    // MARK: Que rutas son de quien

    func testUnPatronCubreSusSubcarpetas() {
        XCTAssertTrue(Owner.pattern("/a/.gradle", covers: "/a/.gradle"))
        XCTAssertTrue(Owner.pattern("/a/.gradle", covers: "/a/.gradle/caches/9.4.1"))
        XCTAssertFalse(Owner.pattern("/a/.gradle", covers: "/a/.gradlew"))
        XCTAssertFalse(Owner.pattern("/a/.gradle", covers: "/a/otra"))
    }

    /// Y al reves: vaciar una carpeta que contiene la de un programa tambien
    /// le toca a el.
    func testUnaCarpetaQueContieneLaDeUnProgramaTambienEsSuya() {
        XCTAssertTrue(Owner.pattern("/a/Library/Caches/Homebrew", covers: "/a/Library/Caches"))
        XCTAssertTrue(Owner.pattern("/a/Caches/Google/AndroidStudio*", covers: "/a/Caches/Google"))
    }

    func testLosComodinesCasanPorComponente() {
        let pattern = "/a/Caches/Google/AndroidStudio*"
        XCTAssertTrue(Owner.pattern(pattern, covers: "/a/Caches/Google/AndroidStudio2025.3"))
        XCTAssertTrue(Owner.pattern(pattern, covers: "/a/Caches/Google/AndroidStudio2025.3/index"))
        XCTAssertFalse(Owner.pattern(pattern, covers: "/a/Caches/Google/Chrome"))
    }

    func testLosPatronesDelCatalogoSeGuardanExpandidos() {
        for owner in Owners.all {
            for path in owner.paths {
                XCTAssertTrue(path.hasPrefix("/"), "\(owner.name): \(path)")
            }
        }
    }

    // MARK: Ocupacion

    func testUnDaemonDeGradleOcupaSusCaches() {
        let daemon = ["java", "-Xmx2g", "-cp", "/x/gradle-launcher.jar",
                      "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "9.4.1"]
        let state = snapshot(processes: [daemon]).occupancy(of: home + "/.gradle/caches/9.4.1")
        XCTAssertEqual(state, .busy("Gradle Daemon"))
    }

    func testSinNadaAbiertoEstaLibre() {
        let state = snapshot(processes: [["/bin/zsh"], ["java", "-jar", "otra.jar"]])
            .occupancy(of: home + "/.gradle/caches/9.4.1")
        XCTAssertEqual(state, .free)
    }

    /// Sin la lista de procesos no se puede saber si el daemon esta vivo, y
    /// eso no es lo mismo que saber que no lo esta.
    func testSinListaDeProcesosNoSeSabe() {
        let state = snapshot(processes: nil).occupancy(of: home + "/.gradle/caches/9.4.1")
        XCTAssertEqual(state, .unknown)
    }

    /// A una app con ventana se la ve aunque no se puedan listar los procesos.
    func testUnaAppAbiertaSeVeSinListaDeProcesos() {
        let xcode = ProcessSnapshot.App(bundleID: "com.apple.dt.Xcode", names: ["Xcode"])
        let state = snapshot(apps: [xcode], processes: nil)
            .occupancy(of: home + "/Library/Developer/Xcode/DerivedData/App-abc")
        XCTAssertEqual(state, .busy("Xcode"))
    }

    /// Lo que no es de nadie esta libre aunque no se sepa nada de los procesos.
    func testLoQueNoEsDeNadieEstaLibre() {
        let state = snapshot(processes: nil).occupancy(of: home + "/Library/Logs/DiagnosticReports")
        XCTAssertEqual(state, .free)
    }

    func testUnSimuladorArrancadoOcupaCoreSimulator() {
        let busy = snapshot(booted: true).occupancy(of: home + "/Library/Developer/CoreSimulator/Caches")
        XCTAssertEqual(busy, .busy("Simulator"))
        let idle = snapshot(booted: false).occupancy(of: home + "/Library/Developer/CoreSimulator/Caches")
        XCTAssertEqual(idle, .free)
    }

    /// Una sesion de Claude Code lee sus shell-snapshots en cada orden.
    func testUnaSesionDeClaudeCodeOcupaSusSnapshots() {
        let snapshots = home + "/.claude/shell-snapshots"
        let cli = ["claude", "--print"]
        XCTAssertEqual(snapshot(processes: [cli]).occupancy(of: snapshots), .busy("Claude Code"))
        // Lanzado por su ruta, el ejecutable se llama como la version.
        let versioned = ["/Users/x/.local/share/claude/versions/2.1.285", "--resume"]
        XCTAssertEqual(snapshot(processes: [versioned]).occupancy(of: snapshots), .busy("Claude Code"))
    }

    func testNpmOcupaSuCacheYNoLaDePnpm() {
        let npm = ["node", "/opt/homebrew/bin/npm", "install"]
        XCTAssertEqual(snapshot(processes: [npm]).occupancy(of: home + "/.npm/_cacache"), .busy("npm"))
        XCTAssertEqual(snapshot(processes: [npm]).occupancy(of: home + "/Library/pnpm/store"), .free)
    }

    func testLosNavegadoresDePruebaSeReconocenPorSuCarpeta() {
        let chromium = [home + "/Library/Caches/ms-playwright/chromium-1140/chrome-mac/Chromium.app/Contents/MacOS/Chromium",
                        "--headless"]
        let state = snapshot(processes: [chromium]).occupancy(of: home + "/Library/Caches/ms-playwright")
        XCTAssertEqual(state, .busy("Playwright"))
    }

    // MARK: Cualquier app abierta

    /// El cajon de sastre vacia `~/Library/Caches/<app>`: con la app abierta,
    /// esa cache es suya aunque el catalogo no la nombre.
    func testUnaAppAbiertaOcupaSuCachePorIdentificador() {
        let slack = ProcessSnapshot.App(bundleID: "com.tinyspeck.slackmacgap", names: ["Slack"])
        let state = snapshot(apps: [slack])
            .occupancy(of: home + "/Library/Caches/com.tinyspeck.slackmacgap")
        XCTAssertEqual(state, .busy("Slack"))
        XCTAssertEqual(snapshot(apps: [slack])
            .occupancy(of: home + "/Library/Caches/com.tinyspeck.slackmacgap.ShipIt"), .busy("Slack"))
    }

    func testUnaAppAbiertaOcupaSusDatosPorNombre() {
        let code = ProcessSnapshot.App(bundleID: "com.example.editor",
                                       names: ["Code", "Electron", "Visual Studio Code"])
        let state = snapshot(apps: [code])
            .occupancy(of: home + "/Library/Application Support/code/Cache")
        XCTAssertEqual(state, .busy("Code"))
    }

    /// Las de Electron guardan la cache con el nombre de la app, no con su
    /// identificador.
    func testUnaAppAbiertaOcupaSuCachePorNombre() {
        let codex = ProcessSnapshot.App(bundleID: "com.openai.codex", names: ["Codex"])
        XCTAssertEqual(snapshot(apps: [codex]).occupancy(of: home + "/Library/Caches/Codex"),
                       .busy("Codex"))
    }

    func testUnNombreParecidoNoBasta() {
        let slack = ProcessSnapshot.App(bundleID: "com.tinyspeck.slackmacgap", names: ["Slack"])
        XCTAssertEqual(snapshot(apps: [slack])
            .occupancy(of: home + "/Library/Caches/com.tinyspeck.slackmacgapX"), .free)
        XCTAssertEqual(snapshot(apps: [slack])
            .occupancy(of: home + "/Library/Application Support/SlackOld/Cache"), .free)
    }

    // MARK: El catalogo

    /// Las filas donde borrar con el programa abierto rompe algo tienen que
    /// tener dueno. Si alguien mueve una ruta y deja de tenerlo, aqui se nota.
    func testLasCachesDeHerramientasTienenDueno() {
        let paths = [
            "/Library/Developer/Xcode/DerivedData",
            "/Library/Developer/XCTestDevices",
            "/Library/Developer/CoreSimulator/Caches",
            "/.gradle/caches", "/.gradle/wrapper/dists", "/.konan/cache",
            "/.npm/_cacache", "/Library/pnpm/store", "/.cargo/registry/cache",
            "/Library/Caches/JetBrains/IntelliJIdea2026.2",
            "/Library/Application Support/Google/Chrome/Default/Cache",
            "/Library/Application Support/Code/CachedData",
            "/.vscode/extensions/una-extension-1.0.0",
            "/.cache/codex-runtimes/tmp-123",
            "/.claude/shell-snapshots",
            "/.cache/node/corepack", "/.expo/versions-cache",
            "/Library/Unity/cache", "/Library/Caches/Unity/upm",
            "/Library/Caches/com.unity3d.UnityEditor/bee", "/Library/Caches/UnityHub",
            "/Library/Application Support/UnityHub/Templates",
        ]
        for relative in paths {
            let path = home + relative
            XCTAssertTrue(Owners.all.contains { $0.owns(path) }, relative)
        }
    }

    func testSimuladorArrancadoSeLeeDelDisco() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sims-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let device = root.appendingPathComponent("UDID-1")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        try (["state": 1] as NSDictionary).write(to: device.appendingPathComponent("device.plist"))
        XCTAssertFalse(Simulators.anyBooted(in: root.path))

        try (["state": 3] as NSDictionary).write(to: device.appendingPathComponent("device.plist"))
        XCTAssertTrue(Simulators.anyBooted(in: root.path))
    }

    /// La lista de procesos de verdad: al menos esta el propio test.
    func testSeListanLosProcesosDeLaMaquina() throws {
        let lines = try XCTUnwrap(Processes.commandLines())
        XCTAssertGreaterThan(lines.count, 1)
        let me = ProcessInfo.processInfo.arguments.first.map { ($0 as NSString).lastPathComponent }
        XCTAssertTrue(lines.contains { ($0.first.map { ($0 as NSString).lastPathComponent }) == me })
    }
}

// MARK: - Antes de borrar

/// Lo ultimo que se mira antes de borrar. Sobre un arbol de prueba dentro de
/// ~/Library/Caches, para que pase las guardas del home igual que una cache.
final class PreflightTests: XCTestCase {

    private var sandbox: String!
    private let tests = "com.haumealabs.maccleaner.tests"

    override func setUpWithError() throws {
        sandbox = NSHomeDirectory() + "/Library/Caches/\(tests)/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    private func make(_ relative: String) throws -> String {
        let path = sandbox + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private let plain = Target(id: "prueba", group: .system, risk: .safe, scope: .contents,
                               patterns: [])

    private func free() -> ProcessSnapshot {
        ProcessSnapshot(apps: [], processes: [], bootedSimulator: false)
    }

    private func record(_ path: String) -> [String: Row.Record] {
        [path: Row.Record(bytes: 10, identity: FileSystem.identity(of: path))]
    }

    func testSinNadaAbiertoYSinCambiosSeBorra() throws {
        let path = try make("caja")
        let check = Engine.preflight([path], target: plain, records: record(path),
                                     scannedAt: Date(), snapshot: free())
        XCTAssertEqual(check.allowed, [path])
        XCTAssertTrue(check.skipped.isEmpty)
    }

    /// La cache de una app abierta se salta, con su motivo.
    func testLoQueEstaEnUsoNoSeBorra() throws {
        let path = try make("caja")
        let app = ProcessSnapshot.App(bundleID: tests, names: ["Pruebas"])
        let busy = ProcessSnapshot(apps: [app], processes: [], bootedSimulator: false)
        let check = Engine.preflight([path], target: plain, records: record(path),
                                     scannedAt: Date(), snapshot: busy)
        XCTAssertTrue(check.allowed.isEmpty)
        XCTAssertNotNil(check.skipped[path])
    }

    /// Ante la duda, no se borra.
    func testSiNoSeSabeQuienEstaAbiertoNoSeBorra() throws {
        let path = try make("caja")
        let owner = Owner(name: "Algo", paths: [sandbox], commands: ["algo"])
        let unknown = ProcessSnapshot(apps: [], processes: nil, bootedSimulator: false)
        let check = Engine.preflight([path], target: plain, records: record(path),
                                     scannedAt: Date(), snapshot: unknown, owners: [owner])
        XCTAssertTrue(check.allowed.isEmpty)
        XCTAssertNotNil(check.skipped[path])
    }

    /// Una carpeta borrada y vuelta a crear despues del analisis ya no es la
    /// que se aprobo.
    func testUnaCarpetaRecreadaNoSeBorra() throws {
        let path = try make("caja")
        let records = record(path)
        try FileManager.default.removeItem(atPath: path)
        // Un inodo nuevo seguro: se ocupa el viejo con otra cosa antes.
        _ = try make("tapon")
        _ = try make("caja")
        XCTAssertNotEqual(FileSystem.identity(of: path), records[path]?.identity)

        let check = Engine.preflight([path], target: plain, records: records,
                                     scannedAt: Date(), snapshot: free())
        XCTAssertTrue(check.allowed.isEmpty)
        XCTAssertNotNil(check.skipped[path])
    }

    /// Lo que ya no esta pasa: borrarlo es no hacer nada.
    func testLoQueYaNoEstaPasa() throws {
        let path = sandbox + "/no-existe"
        let check = Engine.preflight([path], target: plain, records: [:],
                                     scannedAt: Date(), snapshot: free())
        XCTAssertEqual(check.allowed, [path])
    }

    // MARK: Artefactos de proyecto

    private var sweep: Target {
        Target(id: "projects.deps", group: .projects, risk: .caution, scope: .item,
               patterns: [sandbox], expansion: .paths, naming: .project,
               artifacts: ["node_modules"], why: .redownload)
    }

    /// Un `node_modules` en el que alguien ha instalado algo despues del
    /// analisis es el de un proyecto en uso.
    func testUnArtefactoEscritoDespuesDelAnalisisNoSeBorra() throws {
        let path = try make("app/node_modules")
        let records = record(path)
        let scannedAt = Date().addingTimeInterval(-60)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path + "/nuevo.js"))

        let check = Engine.preflight([path], target: sweep, records: records,
                                     scannedAt: scannedAt, snapshot: free())
        XCTAssertTrue(check.allowed.isEmpty)
        XCTAssertNotNil(check.skipped[path])
    }

    func testUnArtefactoQuietoSeBorra() throws {
        let path = try make("app/node_modules")
        let file = path + "/viejo.js"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let old = Date().addingTimeInterval(-3600)
        for item in [file, path] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: item)
        }

        let check = Engine.preflight([path], target: sweep, records: record(path),
                                     scannedAt: Date().addingTimeInterval(-60), snapshot: free())
        XCTAssertEqual(check.allowed, [path])
    }

    func testEscritoDespuesSeDetectaEnLoHondo() throws {
        let path = try make("app/node_modules/a/b/c")
        let since = Date().addingTimeInterval(-60)
        let old = Date().addingTimeInterval(-3600)
        for dir in ["app/node_modules/a/b/c", "app/node_modules/a/b", "app/node_modules/a",
                    "app/node_modules"] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: sandbox + "/" + dir)
        }
        XCTAssertFalse(FileSystem.modified(sandbox + "/app/node_modules", since: since))
        try Data("x".utf8).write(to: URL(fileURLWithPath: path + "/hondo.js"))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        XCTAssertTrue(FileSystem.modified(sandbox + "/app/node_modules", since: since))
    }
}

// MARK: - Seleccion de golpe

/// Un artefacto de proyecto escrito esta semana puede ser el del proyecto
/// abierto. Los atajos de seleccion lo dejan fuera; a mano se puede marcar.
final class RecentArtifactTests: XCTestCase {

    private func item(_ name: String, daysAgo: Double, bytes: Int64) -> SubItem {
        let when = Date().addingTimeInterval(-daysAgo * 24 * 60 * 60)
        return SubItem(path: NSHomeDirectory() + "/Projects/" + name, name: name,
                       usage: FileSystem.Usage(bytes: bytes, files: 1,
                                               newest: time_t(when.timeIntervalSince1970)))
    }

    private func row(sweep: Bool) -> Row {
        let target = Target(id: sweep ? "projects.deps" : "gradle.caches",
                            group: .projects, risk: .caution, scope: sweep ? .item : .contents,
                            patterns: ["~/Projects"], expansion: sweep ? .paths : .children,
                            artifacts: sweep ? ["node_modules"] : [], why: .redownload)
        var row = Row(target: target, selected: false)
        row.items = [item("viejo/node_modules", daysAgo: 90, bytes: 100),
                     item("actual/node_modules", daysAgo: 1, bytes: 40)]
        return row
    }

    func testMarcarDeGolpeDejaFueraLoReciente() {
        var sweep = row(sweep: true)
        sweep.setAll(true)
        XCTAssertEqual(sweep.items.filter(\.selected).map(\.name), ["viejo/node_modules"])
        XCTAssertEqual(sweep.bulkCheckState, .on, "todo lo que entra de golpe esta marcado")
        XCTAssertEqual(sweep.checkState, .mixed, "pero la casilla dice la verdad")
        XCTAssertEqual(sweep.bulkBytes, 100)
    }

    /// Solo en el barrido de proyectos: una version de Gradle usada ayer no
    /// es el proyecto que tienes abierto.
    func testFueraDelBarridoLoRecienteSiEntra() {
        var normal = row(sweep: false)
        normal.setAll(true)
        XCTAssertTrue(normal.items.allSatisfy(\.selected))
        XCTAssertEqual(normal.bulkBytes, 140)
    }

    func testAManoSePuedeMarcarLoReciente() {
        var sweep = row(sweep: true)
        sweep.items[1].selected = true
        XCTAssertEqual(sweep.selectedBytes, 40)
    }

    func testDesmarcarDeGolpeQuitaTambienLoMarcadoAMano() {
        var sweep = row(sweep: true)
        sweep.items[1].selected = true
        sweep.setAll(false)
        XCTAssertFalse(sweep.anySelected)
    }

    func testUnaSemanaEsReciente() {
        XCTAssertTrue(FileSystem.isRecent(Date().addingTimeInterval(-6 * 24 * 3600)))
        XCTAssertFalse(FileSystem.isRecent(Date().addingTimeInterval(-8 * 24 * 3600)))
    }
}

// MARK: - No volver a ofrecer

@MainActor
final class IgnoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clear()
    }

    override func tearDown() {
        clear()
        super.tearDown()
    }

    private func clear() {
        UserDefaults.standard.removeObject(forKey: Engine.ignoredRowsKey)
        UserDefaults.standard.removeObject(forKey: Engine.ignoredPathsKey)
    }

    func testUnaFilaIgnoradaDesapareceYSeRecuerda() {
        let engine = Engine()
        engine.setSelected("homebrew", true)
        engine.ignoreRow("homebrew")
        XCTAssertFalse(engine.rows(in: .tools).contains { $0.id == "homebrew" })
        XCTAssertFalse(engine.anySelected, "lo ignorado no se queda marcado")

        let next = Engine()
        XCTAssertTrue(next.ignoredRows.contains("homebrew"))
        XCTAssertFalse(next.rows(in: .tools).contains { $0.id == "homebrew" })
    }

    func testVolverAOfrecerloTodoLoDevuelve() {
        let engine = Engine()
        engine.ignoreRow("homebrew")
        engine.ignorePath(NSHomeDirectory() + "/.gradle/caches/8.0", in: "gradle.caches")
        XCTAssertEqual(engine.ignoredCount, 2)
        engine.unignoreAll()
        XCTAssertEqual(engine.ignoredCount, 0)
        XCTAssertTrue(engine.rows(in: .tools).contains { $0.id == "homebrew" })
        XCTAssertEqual(Engine().ignoredCount, 0)
    }

    /// Ignorar una carpeta ignora lo que tiene dentro, y nada mas.
    func testIgnorarUnaRutaCubreSuInterior() {
        let ignored: Set<String> = ["/a/b"]
        XCTAssertTrue(Engine.isIgnored("/a/b", in: ignored))
        XCTAssertTrue(Engine.isIgnored("/a/b/c", in: ignored))
        XCTAssertFalse(Engine.isIgnored("/a/bc", in: ignored))
        XCTAssertFalse(Engine.isIgnored("/a", in: ignored))
    }
}

// MARK: - Historial

final class OperationLogTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oplog-" + UUID().uuidString)
            .appendingPathComponent("operations.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func lines() throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testUnaLineaPorRutaConSeisCampos() throws {
        let log = OperationLog(url: url)
        log.begin(rows: 2, toTrash: true)
        log.record(.trash, .ok, bytes: 2048, path: "/Users/x/.npm/_cacache", detail: "npm")
        log.record(.delete, .skipped, bytes: 0, path: "/Users/x/.gradle/caches", detail: "Gradle: en uso")
        log.end(freed: 2048)

        let all = try lines()
        XCTAssertEqual(all.count, 4)
        let fields = all[1].components(separatedBy: "\t")
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(Array(fields[1...4]), ["TRASH", "OK", "2048", "/Users/x/.npm/_cacache"])
        XCTAssertTrue(all[2].contains("\tSKIPPED\t"))
        XCTAssertTrue(all[0].contains("BEGIN"))
        XCTAssertTrue(all[3].contains("END"))
    }

    /// Un nombre con salto de linea o tabulador no puede partir el registro.
    func testUnNombreRaroNoRompeElFormato() throws {
        let log = OperationLog(url: url)
        log.record(.trash, .ok, bytes: 1, path: "/a/b\nc\td", detail: "x\ny")
        let all = try lines()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].components(separatedBy: "\t").count, 6)
    }

    func testAlLlenarseSeAparta() throws {
        let log = OperationLog(url: url, limit: 200)
        for i in 0..<10 {
            log.record(.delete, .ok, bytes: Int64(i), path: "/una/ruta/bastante/larga/\(i)", detail: "x")
        }
        let old = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 400)
    }

    func testSoloSeEscribeAlLimpiar() {
        let log = OperationLog(url: url)
        XCTAssertFalse(log.exists, "crearlo es cosa de la primera limpieza")
    }
}

// MARK: - Runtimes de simulador

final class SimRuntimeTests: XCTestCase {

    private func image(_ id: String, runtime: String, version: String, build: String,
                       bytes: Int64, state: String = "Ready", deletable: Bool = true) -> String {
        """
        "\(id)": {
          "build": "\(build)", "deletable": \(deletable), "identifier": "\(id)",
          "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/\(id)/\(version).simruntime",
          "runtimeIdentifier": "\(runtime)", "sizeBytes": \(bytes), "state": "\(state)",
          "version": "\(version)", "lastUsedAt": "2026-01-02T03:04:05Z"
        }
        """
    }

    private let ios26 = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
    private let ios18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
    private let watch = "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"

    private func orphans(_ images: [String], devices: [String: Int]) -> [SimRuntimes.Runtime]? {
        let imageJSON = "{" + images.joined(separator: ",") + "}"
        let groups = devices.map { runtime, count in
            "\"\(runtime)\": [" + (0..<count).map { "{\"udid\": \"D\($0)\"}" }
                .joined(separator: ",") + "]"
        }
        let deviceJSON = "{\"devices\": {" + groups.joined(separator: ",") + "}}"
        return SimRuntimes.orphans(images: Data(imageJSON.utf8), devices: Data(deviceJSON.utf8))
    }

    /// El que tiene simuladores es justo el que necesitas.
    func testSoloSeOfrecenLosQueNoTienenSimuladores() throws {
        let found = try XCTUnwrap(orphans([
            image("A", runtime: ios26, version: "26.5", build: "23F77", bytes: 8_000_000_000),
            image("B", runtime: ios18, version: "18.0", build: "22A3354", bytes: 7_000_000_000),
        ], devices: [ios26: 2, ios18: 0]))
        XCTAssertEqual(found.map(\.identifier), ["B"])
        XCTAssertEqual(found.first?.title, "iOS 18.0 (22A3354)")
        XCTAssertEqual(found.first?.bytes, 7_000_000_000)
        XCTAssertNotNil(found.first?.lastUsed)
    }

    func testNiLosQueNoEstanListosNiLosQueNoSeDejanBorrar() throws {
        let found = try XCTUnwrap(orphans([
            image("A", runtime: ios18, version: "18.0", build: "1", bytes: 1, state: "Unusable"),
            image("B", runtime: watch, version: "11.0", build: "2", bytes: 1, deletable: false),
        ], devices: [:]))
        XCTAssertTrue(found.isEmpty)
    }

    /// Dos imagenes para el mismo runtime: no se sabe cual usaran los
    /// simuladores que se creen, asi que no se toca ninguna.
    func testDosImagenesDelMismoRuntimeNoSeOfrecen() throws {
        let found = try XCTUnwrap(orphans([
            image("A", runtime: ios18, version: "18.0", build: "1", bytes: 1),
            image("B", runtime: ios18, version: "18.0", build: "2", bytes: 1),
        ], devices: [:]))
        XCTAssertTrue(found.isEmpty)
    }

    func testSeOrdenanPorTamano() throws {
        let found = try XCTUnwrap(orphans([
            image("A", runtime: ios18, version: "18.0", build: "1", bytes: 5),
            image("B", runtime: watch, version: "11.0", build: "2", bytes: 9),
        ], devices: [:]))
        XCTAssertEqual(found.map(\.identifier), ["B", "A"])
        XCTAssertEqual(found.first?.title, "watchOS 11.0 (2)")
    }

    /// Sin la lista de simuladores no hay prueba de que no se usen.
    func testSinListaDeSimuladoresNoSeOfreceNada() {
        let images = Data(("{" + image("A", runtime: ios18, version: "18", build: "1", bytes: 1) + "}").utf8)
        XCTAssertNil(SimRuntimes.orphans(images: images, devices: Data("{}".utf8)))
        XCTAssertNil(SimRuntimes.orphans(images: images, devices: Data("no es json".utf8)))
    }

    /// Lo que aprueba el usuario es una ruta; lo que se borra es lo que simctl
    /// diga hoy que hay en ella. Si ya no esta montado, no hay nada que hacer.
    func testUnRuntimeQueYaNoEstaNoSeBorra() {
        let path = "/Library/Developer/CoreSimulator/Volumes/no-existe/iOS 1.0.simruntime"
        let result = Engine.reclaim(.runtime, paths: [path])
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.leftover[path] ?? 0, 0)
    }
}

// MARK: - Restos de versiones

final class LeftoverTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restos-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func make(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/" + relative,
                                                withIntermediateDirectories: true)
    }

    private func write(_ relative: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: root + "/" + relative))
    }

    func testSoloSonObsoletasLasQueApuntaElEditor() throws {
        try make("ext.vieja-1.0.0")
        try make("ext.nueva-2.0.0")
        try make("ext.falsa-0.1.0")
        try write(".obsolete", #"{"ext.vieja-1.0.0": true, "ext.falsa-0.1.0": false}"#)

        XCTAssertTrue(FileSystem.isObsoleteExtension(root + "/ext.vieja-1.0.0"))
        XCTAssertFalse(FileSystem.isObsoleteExtension(root + "/ext.nueva-2.0.0"))
        XCTAssertFalse(FileSystem.isObsoleteExtension(root + "/ext.falsa-0.1.0"))
    }

    /// Una clave del fichero no puede sacar el borrado de la carpeta.
    func testUnaClaveConRutaNoCuenta() throws {
        try write(".obsolete", #"{"../fuera": true, "a/b": true, "..": true, "bien": true}"#)
        XCTAssertEqual(FileSystem.obsoleteExtensions(in: root), ["bien"])
    }

    func testSinFicheroNoHayObsoletas() {
        XCTAssertTrue(FileSystem.obsoleteExtensions(in: root).isEmpty)
    }

    /// El runtime completo es el que usa Codex y no se ofrece.
    func testElRuntimeCompletoDeCodexNoSeOfrece() throws {
        try make("codex-primary-runtime/dependencies/node")
        try write("codex-primary-runtime/runtime.json", "{}")
        XCTAssertFalse(FileSystem.isStaleCodexRuntime(root + "/codex-primary-runtime"))
    }

    func testUnRuntimeAMediasSiSeOfrece() throws {
        try make("tmp-4f2a/dependencies")
        try make("vacio")
        try make("codex-runtime.partial")
        XCTAssertTrue(FileSystem.isStaleCodexRuntime(root + "/tmp-4f2a"), "nombre de temporal")
        XCTAssertTrue(FileSystem.isStaleCodexRuntime(root + "/vacio"), "sin nada dentro")
        XCTAssertTrue(FileSystem.isStaleCodexRuntime(root + "/codex-runtime.partial"))
    }

    /// Con `runtime.json` pero sin dependencias no esta completo, pero
    /// tampoco abandonado: puede estar bajandose ahora mismo.
    func testUnRuntimeEmpezadoNoSeToca() throws {
        try make("codex-secondary")
        try write("codex-secondary/runtime.json", "{}")
        XCTAssertFalse(FileSystem.isStaleCodexRuntime(root + "/codex-secondary"))
    }
}

// MARK: - Proyectos de Unity

/// Un editor de Unity abierto ocupa todos los proyectos, porque no se sabe
/// cual tiene abierto. Los proyectos son de verdad: se reconocen por su
/// `ProjectSettings/ProjectVersion.txt`, asi que estos tests crean uno.
final class UnityOccupancyTests: XCTestCase {

    private var root: String!
    private let editor = ProcessSnapshot.App(bundleID: "com.unity3d.UnityEditor5.x",
                                             names: ["Unity"])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unity-" + UUID().uuidString).path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/juego/ProjectSettings",
                               withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: root + "/juego/ProjectSettings/ProjectVersion.txt"))
        try fm.createDirectory(atPath: root + "/juego/Library/PackageCache",
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/swiftlib/Library",
                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func snapshot(apps: [ProcessSnapshot.App] = [],
                          processes: [[String]]? = []) -> ProcessSnapshot {
        ProcessSnapshot(apps: apps, processes: processes, bootedSimulator: false)
    }

    func testLaLibraryDeUnProyectoEsDeUnityConElEditorAbierto() {
        let library = root + "/juego/Library"
        XCTAssertEqual(snapshot(apps: [editor]).occupancy(of: library), .busy("Unity"))
        XCTAssertEqual(snapshot(apps: [editor]).occupancy(of: root + "/juego/obj"), .busy("Unity"))
    }

    /// El modo por lotes (`Unity -batchmode`) tambien lo ocupa: es como corren
    /// los builds sin ventana.
    func testUnBuildPorLotesTambienOcupaLosProyectos() {
        let batch = ["/Applications/Unity/Hub/Editor/2022.3.1f1/Unity.app/Contents/MacOS/Unity",
                     "-batchmode", "-projectPath", root + "/juego"]
        XCTAssertEqual(snapshot(processes: [batch]).occupancy(of: root + "/juego/Temp"),
                       .busy("Unity"))
    }

    func testSinEditorAbiertoEstaLibre() {
        XCTAssertEqual(snapshot(processes: [["/bin/zsh"]])
            .occupancy(of: root + "/juego/Library"), .free)
    }

    func testSinListaDeProcesosNoSeSabe() {
        XCTAssertEqual(snapshot(processes: nil).occupancy(of: root + "/juego/Library"), .unknown)
    }

    /// Un `Library` que no es de Unity no es de nadie, aunque Unity este abierto.
    func testUnaLibraryQueNoEsDeUnityNoEsSuya() {
        let library = root + "/swiftlib/Library"
        let unity = Owners.all.first { $0.name == "Unity" }
        XCTAssertEqual(unity?.owns(library), false)
        XCTAssertEqual(snapshot(apps: [editor]).occupancy(of: library), .free)
    }

    func testUnityHubOcupaSusCachesConLaAppAbierta() {
        let hub = ProcessSnapshot.App(bundleID: "com.unity3d.unityhub", names: ["Unity Hub"])
        let caches = NSHomeDirectory() + "/Library/Caches/UnityHub"
        XCTAssertEqual(snapshot(apps: [hub]).occupancy(of: caches), .busy("Unity Hub"))
        XCTAssertEqual(snapshot(apps: []).occupancy(of: caches), .free)
    }
}
