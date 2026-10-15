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
        try touch("app/build.gradle.kts")
        try make("app/node_modules/paquete/build")
        try make("app/ios/Pods")
        try touch("app/ios/Podfile")
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

    /// Un fichero vacio: para los marcadores basta con que exista.
    private func touch(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func find(_ collecting: [String], depth: Int = 8) -> [String] {
        FileSystem.artifactFolders(collecting: collecting,
                                   pruning: Catalog.projectArtifacts,
                                   under: [root.path],
                                   markers: Catalog.artifactMarkers,
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

    /// Las filas juntas no pueden solaparse ni dejarse nada. Las de Unity son
    /// una tercera parte: se podan con las demas, pero las recoge su propia fila.
    func testLasFilasSeRepartenLosArtefactosSinPisarse() {
        let deps = Set(Catalog.dependencyFolders)
        let outputs = Set(Catalog.outputFolders)
        let unity = Set(Catalog.unityFolders)
        XCTAssertTrue(deps.isDisjoint(with: outputs))
        XCTAssertTrue(deps.isDisjoint(with: unity))
        XCTAssertTrue(outputs.isDisjoint(with: unity))
        XCTAssertEqual(deps.union(outputs).union(unity), Set(Catalog.projectArtifacts))
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

    // MARK: - Marcadores

    /// Un `build` sin nada que lo construya al lado es una carpeta mas.
    func testUnBuildSinProyectoAlLadoNoEsUnArtefacto() throws {
        try make("docs/build")
        XCTAssertFalse(find(Catalog.outputFolders).contains("docs/build"))
    }

    /// Y como no es un artefacto, se mira por dentro como cualquier otra.
    func testLoQueNoEsArtefactoSeSigueRecorriendo() throws {
        try make("tools/build/node_modules")
        XCTAssertTrue(find(Catalog.dependencyFolders).contains("tools/build/node_modules"))
    }

    /// El `vendor/` de Rails es codigo de la app; el de Composer, no.
    func testSoloSeRecogeElVendorQueRehaceUnaHerramienta() throws {
        try make("rails/vendor/javascript")
        try touch("rails/Gemfile")
        try touch("php/vendor/autoload.php")

        let deps = find(Catalog.dependencyFolders)
        XCTAssertFalse(deps.contains("rails/vendor"))
        XCTAssertTrue(deps.contains("php/vendor"))
    }

    func testUnEntornoVirtualSeReconocePorSuConfiguracion() throws {
        try touch("py/.venv/pyvenv.cfg")
        try make("otro-py/venv/lib")

        let deps = find(Catalog.dependencyFolders)
        XCTAssertTrue(deps.contains("py/.venv"))
        XCTAssertFalse(deps.contains("otro-py/venv"))
    }

    func testUnTargetNecesitaSuProyecto() throws {
        try make("rust/target/debug")
        try touch("rust/Cargo.toml")
        try make("deploy/target")

        let outputs = find(Catalog.outputFolders)
        XCTAssertTrue(outputs.contains("rust/target"))
        XCTAssertFalse(outputs.contains("deploy/target"))
    }

    /// Un marcador para un nombre que nadie busca no protegeria nada.
    func testCadaMarcadorEsDeUnArtefacto() {
        for name in Catalog.artifactMarkers.keys {
            XCTAssertTrue(Catalog.projectArtifacts.contains(name), name)
        }
    }

    // MARK: - Unity

    /// Un proyecto de Unity de verdad. Lo que lo delata es `ProjectSettings`,
    /// y dentro de su `Library` hay un paquete con `node_modules` que no debe
    /// aparecer en ninguna fila.
    private func makeUnityProject(_ name: String) throws {
        try touch("\(name)/ProjectSettings/ProjectVersion.txt")
        try touch("\(name)/Library/PackageCache/pkg/package.json")
        try make("\(name)/Library/PackageCache/pkg/node_modules")
        try make("\(name)/Temp")
        try make("\(name)/obj")
        try make("\(name)/Assets")
    }

    func testEncuentraLaLibraryTempYObjDeUnProyectoUnity() throws {
        try makeUnityProject("juego")
        XCTAssertEqual(find(Catalog.unityFolders),
                       ["juego/Library", "juego/Temp", "juego/obj"])
    }

    /// Lo de dentro de la Library de Unity es de Unity: ninguna fila de
    /// dependencias ni de compilacion lo recoge, aunque tenga nombres suyos.
    func testLasFilasDeDependenciasYSalidasNoEntranEnUnProyectoUnity() throws {
        try makeUnityProject("juego")
        XCTAssertFalse(find(Catalog.dependencyFolders).contains { $0.hasPrefix("juego/") })
        XCTAssertFalse(find(Catalog.outputFolders).contains { $0.hasPrefix("juego/") })
    }

    /// Un `Library` sin proyecto de Unity al lado es una carpeta de codigo
    /// normal: no se recoge, pero se mira por dentro, y un proyecto de Unity
    /// que haya dentro si aparece.
    func testUnaLibraryQueNoEsDeUnityNoSeRecogePeroSeMiraPorDentro() throws {
        try make("swiftlib/Library/Sources")
        try make("swiftlib/Library/Temp")
        try touch("swiftlib/Package.swift")
        try makeUnityProject("swiftlib/Library/anidado")

        XCTAssertEqual(find(Catalog.unityFolders), [
            "swiftlib/Library/anidado/Library",
            "swiftlib/Library/anidado/Temp",
            "swiftlib/Library/anidado/obj",
        ])
    }

    /// `obj/` es tambien la salida de MSBuild: sin el proyecto de Unity al
    /// lado, no es de Unity.
    func testUnObjDeDotnetNoEsDeUnity() throws {
        try make("dotnet/obj")
        try touch("dotnet/Proyecto.csproj")
        XCTAssertFalse(find(Catalog.unityFolders).contains("dotnet/obj"))
    }

    func testLaFilaDeUnityBarreLosProyectosDeUnity() throws {
        let unity = try XCTUnwrap(Catalog.targets.first { $0.id == "unity.projects" })
        XCTAssertEqual(unity.group, .unity)
        XCTAssertEqual(unity.risk, .rebuild)
        XCTAssertEqual(unity.scope, .item)
        XCTAssertEqual(unity.why, .slowerBuild)
        XCTAssertEqual(unity.artifacts, Catalog.unityFolders)
        XCTAssertEqual(unity.expansion, .paths)
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
                       ["projects.deps", "projects.builds", "unity.projects"])
    }

    /// La regla numero uno vale tambien aqui: se busca dentro del home y en
    /// ningun otro sitio. Esto cubre las carpetas predeterminadas; las que
    /// anade el usuario, tambien fuera del home, estan en `CodeRootsTests`.
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

/// Lo versionado no es un artefacto, se llame como se llame: lo ha escrito
/// alguien. Necesita `git`, asi que se salta si la maquina no lo tiene.
final class VersionedArtifactTests: XCTestCase {

    private var root: URL!
    private var git: String!

    override func setUpWithError() throws {
        git = try XCTUnwrap(Tools.git, "sin git no hay nada que probar")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-sweep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(Tools.run(git, ["init", "-q", root.path]).ok)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func touch(_ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func builds() -> [String] {
        Target(id: "projects.builds",
               group: .projects, risk: .rebuild, scope: .item,
               patterns: [root.path],
               expansion: .paths,
               naming: .project,
               artifacts: Catalog.outputFolders)
            .resolvePaths()
            .map { $0.replacingOccurrences(of: root.path + "/", with: "") }
    }

    /// Como el `build/` de VS Code: tiene `package.json` al lado, asi que pasa
    /// los marcadores, pero es codigo.
    func testUnBuildVersionadoNoSeOfrece() throws {
        try touch("web/package.json")
        try touch("web/build/gulpfile.js")
        try touch("app/build.gradle.kts")
        try touch("app/build/salida.bin")
        XCTAssertTrue(Tools.run(git, ["-C", root.path, "add", "web/build/gulpfile.js"]).ok)

        let found = builds()
        XCTAssertFalse(found.contains("web/build"))
        XCTAssertTrue(found.contains("app/build"), "lo que git no conoce sigue siendo salida")
    }

    /// Un repo entero con nombre de artefacto es de su repo, no basura.
    func testUnRepoConNombreDeArtefactoNoSeOfrece() throws {
        let clon = root.appendingPathComponent("lib/target").path
        try FileManager.default.createDirectory(atPath: clon, withIntermediateDirectories: true)
        try touch("lib/Cargo.toml")
        XCTAssertTrue(Tools.run(git, ["init", "-q", clon]).ok)

        XCTAssertEqual(Tools.versioned([clon], within: [root.path]), [clon])
    }
}
