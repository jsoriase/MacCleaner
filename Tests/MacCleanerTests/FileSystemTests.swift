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

    /// Fija la fecha de modificacion de una ruta, para poder probar la
    /// antiguedad sin esperar meses.
    private func backdate(_ relative: String, days: Double) throws {
        let full = relative.isEmpty
            ? sandbox!
            : (sandbox as NSString).appendingPathComponent(relative)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-days * 24 * 60 * 60)],
            ofItemAtPath: full)
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

    // MARK: - Antiguedad

    /// El mtime sale del mismo `stat` que ya trae `fts`, asi que medir la edad
    /// no cuesta un segundo recorrido.
    func testSeQuedaConLaEscrituraMasRecienteDelArbol() throws {
        try write("viejo/a.bin", bytes: 1024)
        try write("viejo/b.bin", bytes: 1024)
        try backdate("viejo/a.bin", days: 400)
        try backdate("viejo/b.bin", days: 200)
        try backdate("viejo", days: 400)

        let usage = FileSystem.usage(of: sandbox + "/viejo")
        let date = try XCTUnwrap(usage.modified)
        let days = Date().timeIntervalSince(date) / 86400
        XCTAssertEqual(days, 200, accuracy: 1, "gana el fichero mas reciente")
        XCTAssertTrue(FileSystem.isStale(date), "medio ano sin tocar")
    }

    func testUnFicheroSueltoLlevaSuPropiaFecha() throws {
        try write("solo.bin", bytes: 512)
        try backdate("solo.bin", days: 30)

        let usage = FileSystem.usage(of: sandbox + "/solo.bin")
        let date = try XCTUnwrap(usage.modified)
        XCTAssertEqual(Date().timeIntervalSince(date) / 86400, 30, accuracy: 1)
        XCTAssertFalse(FileSystem.isStale(date), "un mes todavia es reciente")
    }

    func testAlSumarGanaLaFechaMasReciente() {
        let viejo = FileSystem.Usage(bytes: 10, files: 1, newest: 1_000)
        let nuevo = FileSystem.Usage(bytes: 20, files: 2, newest: 9_000)
        let total = viejo + nuevo

        XCTAssertEqual(total.bytes, 30)
        XCTAssertEqual(total.files, 3)
        XCTAssertEqual(total.newest, 9_000)
    }

    func testSinMedirNadaNoHayFecha() {
        XCTAssertNil(FileSystem.Usage().modified)
        XCTAssertNil(FileSystem.usage(of: sandbox + "/no-existe").modified)
    }

    // MARK: - Volumen

    func testElVolumenDelHomeSeLee() throws {
        let volume = try XCTUnwrap(FileSystem.homeVolume())
        XCTAssertGreaterThan(volume.total, 0)
        XCTAssertGreaterThanOrEqual(volume.free, 0)
        XCTAssertLessThanOrEqual(volume.free, volume.total)
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

/// Medir es la mitad del producto: una cifra inflada convierte «recuperas 60 GB»
/// en una promesa que el disco no cumple.
final class MedicionHonestaTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("medir-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Un fichero con cuatro nombres ocupa disco una vez. Es justo lo que hace
    /// un almacen de pnpm, y contarlo cuatro veces multiplica por cuatro la
    /// cifra que la app promete recuperar.
    func testUnFicheroConVariosNombresSeCuentaUnaVez() throws {
        let real = dir.appendingPathComponent("paquete.bin")
        try Data(count: 4 * 1024 * 1024).write(to: real)
        let solo = FileSystem.usage(of: dir.path).bytes

        for i in 1...3 {
            try FileManager.default.linkItem(
                at: real, to: dir.appendingPathComponent("enlace\(i).bin"))
        }
        let conEnlaces = FileSystem.usage(of: dir.path)

        XCTAssertEqual(conEnlaces.bytes, solo, "los enlaces duros no ocupan disco")
        XCTAssertEqual(conEnlaces.files, 4, "pero si son cuatro entradas")
    }

    /// Dos ficheros distintos si suman.
    func testDosFicherosDistintosSuman() throws {
        try Data(count: 2 * 1024 * 1024).write(to: dir.appendingPathComponent("a.bin"))
        let uno = FileSystem.usage(of: dir.path).bytes
        try Data(count: 2 * 1024 * 1024).write(to: dir.appendingPathComponent("b.bin"))
        let dos = FileSystem.usage(of: dir.path).bytes
        XCTAssertGreaterThan(dos, uno + 1_000_000)
    }

    /// Un fichero disperso ocupa sus bloques, no lo que declara. Es lo que
    /// separa los 15 GB reales del `Docker.raw` de los 228 que dice medir.
    func testUnFicheroDispersoOcupaLoQueOcupa() throws {
        let sparse = dir.appendingPathComponent("disperso.img")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 8 * 1024 * 1024 * 1024)   // 8 GB declarados
        try handle.close()

        let usage = FileSystem.usage(of: dir.path)
        XCTAssertLessThan(usage.bytes, 10 * 1024 * 1024,
                          "sin escribir nada no ocupa nada, por mucho que declare 8 GB")
    }
}

/// El total de la cabecera es la suma de las filas: si dos filas apuntan a la
/// misma ruta, promete el doble de lo que hay.
final class SolapesTests: XCTestCase {

    func testNingunaRutaSeCuentaEnDosFilas() {
        let map = Engine.resolve(Catalog.targets)
        var vistas: [(id: String, path: String)] = []
        for (id, paths) in map { for path in paths { vistas.append((id, path)) } }

        for i in vistas.indices {
            for j in vistas.indices where j > i {
                let a = vistas[i], b = vistas[j]
                guard a.id != b.id else { continue }
                let anidadas = a.path == b.path
                    || a.path.hasPrefix(b.path + "/")
                    || b.path.hasPrefix(a.path + "/")
                XCTAssertFalse(anidadas,
                               "\(a.id) y \(b.id) cuentan lo mismo: "
                               + "\(FileSystem.prettyPath(a.path)) / \(FileSystem.prettyPath(b.path))")
            }
        }
    }
}
