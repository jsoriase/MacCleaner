import XCTest
@testable import MacCleaner

// MARK: - Validacion

/// Que carpetas se aceptan como carpeta de codigo. La parte sin disco se
/// prueba con cadenas, asi que `/Volumes` se puede probar sin tener discos.
final class CodeRootsCheckTests: XCTestCase {

    private let home = NSHomeDirectory()

    private func check(_ path: String) -> CodeRoots.Rejection? {
        CodeRoots.check(canonical: path, home: home)
    }

    func testAceptaUnaCarpetaDeUnDisco() {
        XCTAssertNil(check("/Volumes/External/HaumeaLabs"))
    }

    func testAceptaCarpetasDentroDelHome() {
        XCTAssertNil(check(home + "/Projects"))
        XCTAssertNil(check(home + "/Developer"))
    }

    func testRechazaLoDemasiadoAmplio() {
        XCTAssertEqual(check("/"), .tooBroad)
        XCTAssertEqual(check("/Volumes"), .tooBroad)
        XCTAssertEqual(check("/Users"), .tooBroad)
        XCTAssertEqual(check(home), .tooBroad)
    }

    func testRechazaLaRaizDeUnDisco() {
        XCTAssertEqual(check("/Volumes/External"), .volumeRoot)
    }

    func testRechazaLasCarpetasDeSistemaDentroDeUnDisco() {
        XCTAssertEqual(check("/Volumes/External/System"), .system)
        XCTAssertEqual(check("/Volumes/External/Users/x"), .system)
        XCTAssertEqual(check("/Volumes/TM/Backups.backupdb/x"), .system)
        XCTAssertEqual(check("/Volumes/External/Imagen.sparsebundle/x"), .system)
    }

    func testRechazaElSistemaYLosOtrosUsuarios() {
        for path in ["/System", "/usr/local/src", "/opt/code", "/private/tmp/x", "/Users/otro/code"] {
            XCTAssertEqual(check(path), .system, path)
        }
    }

    func testRechazaLaBibliotecaYLoProtegidoDelHome() {
        XCTAssertEqual(check(home + "/Library"), .protected)
        XCTAssertEqual(check(home + "/Library/Caches/x"), .protected)
        XCTAssertEqual(check(home + "/Documents/code"), .protected)
    }

    /// Lo que no tiene ni forma de ruta valida se rechaza antes de mirar el disco.
    func testUnaRutaRelativaOConConControlNoEsValida() {
        XCTAssertEqual(CodeRoots.check("relativa/ruta"), .invalid)
        XCTAssertEqual(CodeRoots.check(home + "/../x"), .invalid)
        XCTAssertEqual(CodeRoots.check(home + "/a\nb"), .invalid)
    }

    func testUnaCarpetaInexistenteNoEsUnaRaiz() {
        XCTAssertEqual(CodeRoots.check(home + "/no-existe-\(UUID().uuidString)"), .missing)
    }
}

// MARK: - Almacenamiento

/// Lo que se guarda: la ruta resuelta, sin duplicados ni predeterminadas, y
/// `load` que filtra sin borrar. Usa un dominio propio de UserDefaults.
/// Las carpetas de prueba van dentro del home, la unica zona que se acepta
/// sin un disco externo.
final class CodeRootsStoreTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!
    private var base: String!

    override func setUpWithError() throws {
        suiteName = "maccleaner.tests.\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        base = NSHomeDirectory() + "/.maccleaner-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base + "/code",
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: base)
    }

    func testGuardaLaRutaResuelta() throws {
        let real = base + "/code"
        let link = base + "/atajo"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        XCTAssertNil(CodeRoots.add(link, to: suite))
        let resolved = try XCTUnwrap(CodeRoots.canonicalPath(real))
        XCTAssertEqual(CodeRoots.stored(suite), [resolved])
    }

    func testNoAdmiteDuplicados() {
        XCTAssertNil(CodeRoots.add(base + "/code", to: suite))
        XCTAssertEqual(CodeRoots.add(base + "/code", to: suite), .duplicate)
        XCTAssertEqual(CodeRoots.stored(suite).count, 1)
    }

    func testNoAdmiteLasPredeterminadas() throws {
        guard let existing = Catalog.codeRoots
            .map(FileSystem.expandTilde)
            .first(where: { FileManager.default.fileExists(atPath: $0) })
        else { throw XCTSkip("ninguna carpeta predeterminada existe en esta maquina") }

        XCTAssertEqual(CodeRoots.add(existing, to: suite), .duplicate)
        XCTAssertTrue(CodeRoots.stored(suite).isEmpty)
    }

    func testRechazaLoQueNoExisteOEsRelativo() {
        XCTAssertEqual(CodeRoots.add(base + "/no-existe", to: suite), .missing)
        XCTAssertEqual(CodeRoots.add("relativa/ruta", to: suite), .invalid)
        XCTAssertEqual(CodeRoots.add(base + "/../x", to: suite), .invalid)
        XCTAssertTrue(CodeRoots.stored(suite).isEmpty)
    }

    /// Si la carpeta desaparece, no aporta raiz, pero sigue guardada: un disco
    /// desmontado que vuelve a montarse tiene que volver a contar.
    func testLoadFiltraLoQueDesapareceSinBorrarlo() throws {
        let dir = base + "/temporal"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertNil(CodeRoots.add(dir, to: suite))
        let saved = try XCTUnwrap(CodeRoots.canonicalPath(dir))
        XCTAssertEqual(CodeRoots.load(suite), [saved])

        try FileManager.default.removeItem(atPath: dir)
        XCTAssertEqual(CodeRoots.load(suite), [])
        XCTAssertEqual(CodeRoots.stored(suite), [saved])
    }

    func testRemoveQuitaLaRuta() throws {
        XCTAssertNil(CodeRoots.add(base + "/code", to: suite))
        let saved = try XCTUnwrap(CodeRoots.stored(suite).first)
        CodeRoots.remove(saved, from: suite)
        XCTAssertTrue(CodeRoots.stored(suite).isEmpty)
    }
}

// MARK: - Raices de los barridos

/// Las carpetas del usuario entran en los barridos y en ningun otro sitio.
final class CodeRootsSearchTests: XCTestCase {

    private let extra = "/Volumes/External/HaumeaLabs"

    func testLasDelUsuarioSoloEntranEnLosBarridos() throws {
        let sweep = try XCTUnwrap(Catalog.targets.first { $0.id == "unity.projects" })
        let plain = try XCTUnwrap(Catalog.targets.first { !$0.isSweep })
        XCTAssertTrue(sweep.searchRoots(userRoots: [extra]).contains(extra))
        XCTAssertFalse(plain.searchRoots(userRoots: [extra]).contains(extra))
    }

    func testNoRepiteRaices() throws {
        let sweep = try XCTUnwrap(Catalog.targets.first { $0.id == "unity.projects" })
        let roots = sweep.searchRoots(userRoots: [extra, extra, NSHomeDirectory() + "/Projects"])
        XCTAssertEqual(roots.count, Set(roots).count)
    }
}

// MARK: - La parte sin disco de la red de seguridad

/// `isInCodeRoot` sin tocar el disco: que se acepta dentro de una raiz elegida
/// y que no.
final class CodeRootArtifactTests: XCTestCase {

    private let root = "/Volumes/E/H"

    func testAceptaUnArtefactoDentroDeLaRaiz() {
        XCTAssertTrue(Engine.isInCodeRoot("/Volumes/E/H/Game/Library",
                                          real: "/Volumes/E/H/Game/Library",
                                          canonicalRoots: [root]))
    }

    /// La raiz misma no se borra, aunque su nombre sea de artefacto.
    func testNoAceptaLaPropiaRaiz() {
        XCTAssertFalse(Engine.isInCodeRoot("/Volumes/E/build", real: "/Volumes/E/build",
                                           canonicalRoots: ["/Volumes/E/build"]))
    }

    func testNoAceptaUnNombreQueNoEsArtefacto() {
        XCTAssertFalse(Engine.isInCodeRoot("/Volumes/E/H/Game/Assets",
                                           real: "/Volumes/E/H/Game/Assets",
                                           canonicalRoots: [root]))
    }

    func testNoSaleDeLaRaizPorUnEnlace() {
        XCTAssertFalse(Engine.isInCodeRoot("/Volumes/E/H/enlace/Library",
                                           real: "/Volumes/X/otro/Library",
                                           canonicalRoots: [root]))
    }

    func testNoAceptaPuntoPunto() {
        let path = "/Volumes/E/H/Game/../Game/Library"
        XCTAssertFalse(Engine.isInCodeRoot(path, real: path, canonicalRoots: [root]))
    }

    func testSinRaicesNoHayNada() {
        XCTAssertFalse(Engine.isInCodeRoot("/Volumes/E/H/Game/Library", roots: []))
    }

    /// Una raiz que es la de un disco no sirve, aunque exista.
    func testUnaRaizQueEsDeUnDiscoNoSirve() {
        XCTAssertFalse(Engine.isInCodeRoot("/Volumes/External/Game/Library",
                                           roots: ["/Volumes/External"]))
    }

    func testFueraDelHomeSinRaicesNoSeBorra() {
        XCTAssertFalse(Engine.mayDelete("/Volumes/External/HaumeaLabs/Game/Library"))
        XCTAssertFalse(Engine.mayDelete("/Volumes/External/HaumeaLabs/Game/Library", codeRoots: []))
    }
}

// MARK: - Disco real

/// Una carpeta de codigo de verdad en un disco externo, con un proyecto de
/// Unity dentro. Todo se crea bajo una carpeta temporal y se borra al
/// terminar. Si no hay un disco escribible distinto del de arranque, se omite.
final class CodeRootDiskTests: XCTestCase {

    private var base: String!
    private var code: String!

    override func setUpWithError() throws {
        let volume = try externalVolume()
        base = volume + "/.maccleaner-tests-\(UUID().uuidString)"
        code = base + "/code"
        try file(code + "/Game/ProjectSettings/ProjectVersion.txt")
        try file(code + "/Game/Library/x")
        try file(code + "/Game/Assets/y")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    /// El primer volumen montado que se puede escribir y que no es el de arranque.
    /// `canonicalPath` lo resuelve: el de arranque, `Macintosh HD`, cae en `/`.
    private func externalVolume() throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in names.sorted() {
            let path = "/Volumes/" + name
            guard let real = CodeRoots.canonicalPath(path), real.hasPrefix("/Volumes/"),
                  FileManager.default.isWritableFile(atPath: path)
            else { continue }
            return real
        }
        throw XCTSkip("no hay un disco externo escribible distinto del de arranque")
    }

    /// Crea un fichero vacio, con sus carpetas.
    private func file(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: path, contents: Data())
    }

    func testLaCarpetaEsAceptable() {
        XCTAssertNil(CodeRoots.check(code))
    }

    func testLaRaizDelUsuarioSaleEnElBarrido() throws {
        let unity = try XCTUnwrap(Catalog.targets.first { $0.id == "unity.projects" })
        XCTAssertTrue(unity.searchRoots(userRoots: [code]).contains(code))
    }

    /// Un barrido de Unity solo sobre la carpeta elegida: encuentra la Library
    /// del proyecto y no el `Assets`, que no es artefacto.
    func testElBarridoEncuentraLaLibraryDeLaRaiz() throws {
        let sweep = Target(id: "unity.projects",
                           group: .unity, risk: .rebuild, scope: .item,
                           patterns: [code],
                           expansion: .paths,
                           naming: .project,
                           artifacts: Catalog.unityFolders)
        let paths = sweep.resolvePaths(userRoots: [])
        XCTAssertTrue(paths.contains(code + "/Game/Library"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.hasSuffix("/Assets") })
    }

    /// Una `Library` con el nombre de Unity pero sin proyecto al lado no es un
    /// artefacto: aunque este dentro de la raiz elegida, no se borra.
    func testUnaLibrarySinMarcadorDeUnityNoSeBorra() throws {
        try file(code + "/Otra/Library/x")
        XCTAssertFalse(Engine.mayDelete(code + "/Otra/Library", codeRoots: [code]))
        XCTAssertTrue(Engine.mayDelete(code + "/Game/Library", codeRoots: [code]))
    }

    func testMayDeleteSoloConLaRaizElegida() {
        let library = code + "/Game/Library"
        let assets = code + "/Game/Assets"
        XCTAssertTrue(Engine.mayDelete(library, codeRoots: [code]))
        XCTAssertFalse(Engine.mayDelete(assets, codeRoots: [code]))
        XCTAssertFalse(Engine.mayDelete(library, codeRoots: []))
    }

    /// Un enlace en medio que lleva fuera de la raiz no abre el borrado.
    func testUnEnlaceQueSaleDeLaRaizNoSeBorra() throws {
        try file(base + "/fuera/Library/x")
        try FileManager.default.createSymbolicLink(atPath: code + "/Otro",
                                                   withDestinationPath: base + "/fuera")
        XCTAssertFalse(Engine.mayDelete(code + "/Otro/Library", codeRoots: [code]))
    }

    /// Sin raices no se borra; con ellas, borra la Library y deja los fuentes.
    func testEraseBorraLaLibraryYDejaLosFuentes() {
        let library = code + "/Game/Library"
        let assets = code + "/Game/Assets"

        let refused = Engine.erase(paths: [library], scope: .item, toTrash: false, codeRoots: [])
        XCTAssertEqual(refused.errors.count, 1)
        XCTAssertTrue(FileSystem.exists(library))

        let done = Engine.erase(paths: [library], scope: .item, toTrash: false, codeRoots: [code])
        XCTAssertEqual(done.removed, 1)
        XCTAssertFalse(FileSystem.exists(library))
        XCTAssertTrue(FileSystem.exists(assets))
    }
}
