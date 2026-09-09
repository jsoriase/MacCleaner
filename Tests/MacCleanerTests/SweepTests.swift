import XCTest
@testable import MacCleaner

/// El barrido de artefactos es la unica parte del catalogo que no sabe de
/// antemano que va a borrar: sale de recorrer las carpetas de codigo. Estos
/// tests fijan donde mira, donde no baja y como se titula lo que encuentra.
final class SweepTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-" + UUID().uuidString)
        try make("app/src/main")
        try make("app/build")
        try make("app/node_modules/paquete/build")
        try make("app/ios/Pods")
        try make(".git/objects/build")
        try make("otro/cmake-build-debug")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private func find(_ collecting: [String], depth: Int = 8) -> [String] {
        FileSystem.artifactFolders(collecting: collecting,
                                   pruning: Catalog.projectArtifacts,
                                   under: [root.path],
                                   maxDepth: depth)
            .map { $0.replacingOccurrences(of: root.path + "/", with: "") }
            .sorted()
    }

    // MARK: - Que encuentra

    func testEncuentraLasDependenciasDondeEsteElCodigo() {
        XCTAssertEqual(find(Catalog.dependencyFolders),
                       ["app/ios/Pods", "app/node_modules"])
    }

    func testEncuentraLasSalidasDeCompilacion() {
        XCTAssertEqual(find(Catalog.outputFolders),
                       ["app/build", "otro/cmake-build-debug"])
    }

    /// Lo importante del barrido: en cuanto una carpeta hace match se poda. Sin
    /// eso, el `build` de dentro de `node_modules` se contaria dos veces.
    func testNoBajaDentroDeUnArtefacto() {
        XCTAssertFalse(find(Catalog.outputFolders).contains("app/node_modules/paquete/build"))
    }

    /// Las dos filas juntas no pueden solaparse ni dejarse nada.
    func testLasDosFilasSeRepartenLosArtefactosSinPisarse() {
        let deps = Set(Catalog.dependencyFolders)
        let outputs = Set(Catalog.outputFolders)
        XCTAssertTrue(deps.isDisjoint(with: outputs))
        XCTAssertEqual(deps.union(outputs), Set(Catalog.projectArtifacts))
    }

    func testUnCarpetaOcultaNoSeRecorre() {
        XCTAssertFalse(find(Catalog.outputFolders).contains(".git/objects/build"))
    }

    func testMasAlladeLaProfundidadMaximaNoSeMira() {
        XCTAssertEqual(find(Catalog.outputFolders, depth: 1), [],
                       "a nivel 1 solo estan app, otro y .git")
        XCTAssertTrue(find(Catalog.outputFolders, depth: 2).contains("app/build"))
    }

    func testSinCarpetasDeCodigoNoDevuelveNada() {
        XCTAssertEqual(FileSystem.artifactFolders(collecting: Catalog.outputFolders,
                                                  pruning: Catalog.projectArtifacts,
                                                  under: []), [])
    }

    // MARK: - Nombres

    func testElComodinFinalValeComoPrefijo() {
        XCTAssertTrue(FileSystem.matchesArtifact("cmake-build-debug", ["cmake-build-*"]))
        XCTAssertTrue(FileSystem.matchesArtifact("node_modules", ["node_modules"]))
        XCTAssertFalse(FileSystem.matchesArtifact("nodo_modules", ["node_modules"]))
        XCTAssertFalse(FileSystem.matchesArtifact("cmake", ["cmake-build-*"]))
    }

    /// Diez carpetas llamadas `build` son la misma fila diez veces si no dicen
    /// de que proyecto son.
    func testUnArtefactoSeTitulaConSuSitio() {
        let path = NSHomeDirectory() + "/Projects/HaumeaImages/composeApp/build"
        XCTAssertEqual(Engine.label(for: path, naming: .project),
                       "Projects/HaumeaImages/composeApp/build")
    }

    func testUnaCarpetaNormalSeQuedaConSuNombre() {
        XCTAssertNil(Engine.label(for: NSHomeDirectory() + "/.gradle/caches/9.4.1",
                                  naming: .folder))
    }

    // MARK: - Catalogo

    func testSoloEstasFilasBarrenElArbol() {
        XCTAssertEqual(Set(Catalog.targets.filter(\.isSweep).map(\.id)),
                       ["projects.deps", "projects.builds"])
    }

    /// La regla numero uno vale tambien aqui: se busca dentro del home y en
    /// ningun otro sitio.
    func testSoloSeBuscaDentroDelHome() {
        for pattern in Catalog.codeRoots {
            XCTAssertTrue(pattern.hasPrefix("~/"), pattern)
        }
        for target in Catalog.targets where target.isSweep {
            for path in target.patterns.flatMap({ FileSystem.expand($0) }) {
                XCTAssertTrue(path.hasPrefix(NSHomeDirectory() + "/"), path)
            }
        }
    }

    /// El camino completo: del patron a las rutas que acabaran en la lista.
    func testUnaFilaDeBarridoResuelveSusRutasRecorriendoElArbol() throws {
        let target = Target(id: "projects.builds",
                            group: .projects, risk: .rebuild, scope: .item,
                            patterns: [root.path],
                            expansion: .paths,
                            naming: .project,
                            artifacts: Catalog.outputFolders)
        let paths = target.resolvePaths()
        XCTAssertTrue(paths.contains(root.appendingPathComponent("app/build").path))
        XCTAssertFalse(paths.contains(root.path), "la raiz no es un artefacto")
    }

    /// Y el de una fila normal sigue siendo el de siempre: expandir el patron.
    func testUnaFilaNormalSigueSaliendoDelPatron() {
        let target = Target(id: "gradle.caches",
                            group: .jvm, risk: .rebuild, scope: .contents,
                            patterns: [root.path])
        XCTAssertEqual(target.resolvePaths(), [root.path])
    }

    /// Un artefacto se borra entero, nunca se vacia.
    func testUnArtefactoSeBorraEntero() {
        for target in Catalog.targets where target.isSweep {
            XCTAssertEqual(target.scope, .item, target.id)
        }
    }
}
