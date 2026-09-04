import XCTest
@testable import MacCleaner

/// Pruebas sobre un arbol sintetico: nada de esto toca datos reales.
final class FileSystemTests: XCTestCase {

    private var sandbox: String!

    override func setUpWithError() throws {
        // Dentro de ~/Library/Caches para que pase la guarda isSafe y para que
        // sea, literalmente, una cache descartable.
        sandbox = NSHomeDirectory()
            + "/Library/Caches/com.haumealabs.maccleaner.tests/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let full = (sandbox as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: full))
    }

    // MARK: - Medicion

    func testMideTamanoYNumeroDeArchivos() throws {
        try write("a.bin", bytes: 4096)
        try write("sub/b.bin", bytes: 4096)
        try write("sub/hondo/c.bin", bytes: 4096)

        let usage = FileSystem.usage(of: sandbox)
        XCTAssertEqual(usage.files, 3)
        // Bloques asignados: al menos los 12 KB de contenido.
        XCTAssertGreaterThanOrEqual(usage.bytes, 12 * 1024)
    }

    func testCarpetaInexistenteMideCero() {
        let usage = FileSystem.usage(of: sandbox + "/no-existe")
        XCTAssertEqual(usage.bytes, 0)
        XCTAssertEqual(usage.files, 0)
    }

    func testNoSigueEnlacesSimbolicos() throws {
        try write("real/grande.bin", bytes: 100_000)
        try FileManager.default.createSymbolicLink(
            atPath: sandbox + "/enlace",
            withDestinationPath: sandbox + "/real")

        let usage = FileSystem.usage(of: sandbox)
        // El enlace cuenta como 1 archivo, no como una copia del arbol.
        XCTAssertEqual(usage.files, 2)
        XCTAssertLessThan(usage.bytes, 200_000)
    }

    // MARK: - Expansion de patrones

    func testExpandeComodines() throws {
        try write("proj-uno/data.bin", bytes: 10)
        try write("proj-dos/data.bin", bytes: 10)
        try write("otro/data.bin", bytes: 10)

        let matches = FileSystem.expand(sandbox + "/proj-*")
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches.allSatisfy { $0.contains("proj-") })
    }

    func testNoDevuelveRutasQueNoExisten() {
        XCTAssertTrue(FileSystem.expand(sandbox + "/fantasma").isEmpty)
        XCTAssertTrue(FileSystem.expand("~/carpeta-que-no-existe-jamas").isEmpty)
    }

    func testExpandeLaVirgulilla() {
        let matches = FileSystem.expand("~/Library")
        XCTAssertEqual(matches, [NSHomeDirectory() + "/Library"])
    }

    // MARK: - Borrado

    func testScopeContentsVaciaLaCarpetaPeroLaConserva() throws {
        try write("caja/uno.bin", bytes: 2048)
        try write("caja/dos/tres.bin", bytes: 2048)
        let caja = sandbox + "/caja"

        let result = Engine.erase(paths: [caja], scope: .contents, toTrash: false)

        XCTAssertTrue(result.errors.isEmpty, "errores: \(result.errors)")
        XCTAssertEqual(result.removed, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: caja), "la carpeta debe seguir ahi")
        XCTAssertEqual(FileSystem.children(of: caja).count, 0, "pero vacia")
    }

    func testScopeItemBorraLaRutaEntera() throws {
        try write("caja/uno.bin", bytes: 2048)
        let caja = sandbox + "/caja"

        let result = Engine.erase(paths: [caja], scope: .item, toTrash: false)

        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: caja))
    }

    func testNoBorraNadaFueraDelHome() throws {
        let result = Engine.erase(paths: ["/tmp"], scope: .contents, toTrash: false)
        XCTAssertEqual(result.removed, 0)
        XCTAssertFalse(result.errors.isEmpty, "deberia rechazar la ruta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp"))
    }

    func testNoBorraCarpetasProtegidas() {
        let musica = NSHomeDirectory() + "/Library/Caches/com.apple.Music"
        let result = Engine.erase(paths: [musica], scope: .contents, toTrash: false)
        XCTAssertEqual(result.removed, 0)
    }

    func testContabilizaLoQueNoHaPodidoBorrar() throws {
        try write("bloqueada/dentro.bin", bytes: 8192)
        let bloqueada = sandbox + "/bloqueada"
        // Sin permiso de escritura en el padre, unlink del hijo falla.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bloqueada)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: bloqueada) }

        let result = Engine.erase(paths: [bloqueada], scope: .contents, toTrash: false)

        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertGreaterThan(result.failedBytes, 0, "debe medir lo que quedo sin borrar")
    }
}
