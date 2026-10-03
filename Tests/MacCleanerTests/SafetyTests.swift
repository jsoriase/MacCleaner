import XCTest
@testable import MacCleaner

/// El riesgo real de esta app es borrar algo que no toca.
/// Estos tests cubren la red de seguridad antes que ninguna otra cosa.
final class SafetyTests: XCTestCase {

    private let home = NSHomeDirectory()

    // MARK: - Guardas de borrado

    func testRechazaRutasFueraDelHome() {
        XCTAssertFalse(Engine.isSafe("/"))
        XCTAssertFalse(Engine.isSafe("/System"))
        XCTAssertFalse(Engine.isSafe("/Applications/Safari.app"))
        XCTAssertFalse(Engine.isSafe("/usr/local/bin"))
        XCTAssertFalse(Engine.isSafe("/Volumes/External"))
    }

    func testRechazaElHomeYSusCarpetasDeSistema() {
        XCTAssertFalse(Engine.isSafe(home))
        XCTAssertFalse(Engine.isSafe(home + "/"))
        XCTAssertFalse(Engine.isSafe(home + "/Library"))
        XCTAssertFalse(Engine.isSafe(home + "/Documents"))
        XCTAssertFalse(Engine.isSafe(home + "/Desktop"))
        XCTAssertFalse(Engine.isSafe(home + "/Downloads"))
        XCTAssertFalse(Engine.isSafe(home + "/Pictures"))
    }

    /// Estas si tienen que pasar: son carpetas de herramientas que algun
    /// target necesita vaciar y estan a un solo nivel del home.
    func testAceptaCarpetasDeHerramientaDePrimerNivel() {
        XCTAssertTrue(Engine.isSafe(home + "/.Trash"))
        XCTAssertTrue(Engine.isSafe(home + "/.pnpm-store"))
        XCTAssertTrue(Engine.isSafe(home + "/.dartServer"))
    }

    func testRechazaEscapesConDosPuntos() {
        XCTAssertFalse(Engine.isSafe(home + "/Library/../.."))
        XCTAssertFalse(Engine.isSafe(home + "/Library/Caches/../../.."))
    }

    func testAceptaRutasDeCacheLegitimas() {
        XCTAssertTrue(Engine.isSafe(home + "/Library/Caches/Homebrew"))
        XCTAssertTrue(Engine.isSafe(home + "/.gradle/caches"))
        XCTAssertTrue(Engine.isSafe(home + "/Library/Developer/Xcode/DerivedData"))
    }

    // MARK: - Rutas protegidas por TCC

    func testIgnoraCarpetasProtegidasPorTCC() {
        XCTAssertTrue(FileSystem.isProtected(home + "/Library/Caches/com.apple.AMPLibraryAgent"))
        XCTAssertTrue(FileSystem.isProtected(home + "/Library/Caches/com.apple.Music"))
        XCTAssertTrue(FileSystem.isProtected(home + "/Library/Caches/com.apple.Music/subcarpeta"))
        XCTAssertTrue(FileSystem.isProtected(home + "/Library/Caches/com.apple.Safari"))
        XCTAssertTrue(FileSystem.isProtected(home + "/Pictures/Photos Library.photoslibrary"))
        XCTAssertTrue(FileSystem.isProtected(home + "/Library/Application Support/MobileSync/Backup"))
    }

    func testNoConfundeCachesNormalesConProtegidas() {
        XCTAssertFalse(FileSystem.isProtected(home + "/Library/Caches/Homebrew"))
        XCTAssertFalse(FileSystem.isProtected(home + "/Library/Caches/com.apple.dt.Xcode"))
        XCTAssertFalse(FileSystem.isProtected(home + "/.gradle/caches"))
    }

    func testNingunTargetDelCatalogoApuntaAUnaRutaProhibida() {
        for target in Catalog.targets {
            for path in target.patterns.flatMap({ FileSystem.expand($0) }) {
                XCTAssertTrue(Engine.isSafe(path),
                              "\(target.id) expande a una ruta insegura: \(path)")
            }
        }
    }

    /// Entrar en el contenedor de otra app saca, desde Sonoma, el aviso de
    /// «acceder a datos de otras apps» en cada analisis. Filtrar la ruta
    /// despues no sirve: `glob` ya ha entrado para encontrarla, asi que la
    /// regla tiene que estar en los patrones.
    ///
    /// Docker es la excepcion: no esta en sandbox y solo usa esa carpeta para
    /// guardar sus datos.
    func testNingunPatronEntraEnElContenedorDeOtraApp() {
        let permitidos: Set<String> = ["com.docker.docker"]
        for target in Catalog.targets {
            for pattern in target.patterns {
                let partes = pattern.split(separator: "/").map(String.init)
                guard partes.count > 2, partes[0] == "~", partes[1] == "Library" else { continue }

                // `~/Library/*/...` entraria en Containers sin nombrarla.
                XCTAssertFalse(partes[2].contains("*"), "\(target.id): \(pattern)")
                XCTAssertNotEqual(partes[2], "Group Containers", "\(target.id): \(pattern)")
                if partes[2] == "Containers" {
                    XCTAssertTrue(partes.count > 3 && permitidos.contains(partes[3]),
                                  "\(target.id): \(pattern)")
                }
            }
        }
    }
}

/// Safari no se puede limpiar sin Acceso total al disco, que esta app no pide.
/// Lo que si se puede es asegurarse de que no se cuela por una puerta lateral.
final class SafariTests: XCTestCase {

    func testLasCachesHermanasDeUnaAppProtegidaTambienLoEstan() {
        let caches = NSHomeDirectory() + "/Library/Caches/"
        XCTAssertTrue(FileSystem.isProtected(caches + "com.apple.Safari"))
        XCTAssertTrue(FileSystem.isProtected(caches + "com.apple.Safari.SafeBrowsing"),
                      "el cajon de sastre no puede llevarsela por delante")
        XCTAssertTrue(FileSystem.isProtected(caches + "com.apple.Photos.Analytics"))
    }

    /// Y que el prefijo no se lleve por delante a un tercero con nombre parecido.
    func testUnNombreParecidoNoSeProtegeSinMotivo() {
        let caches = NSHomeDirectory() + "/Library/Caches/"
        XCTAssertFalse(FileSystem.isProtected(caches + "com.apple.SafariClone"))
        XCTAssertFalse(FileSystem.isProtected(caches + "org.mozilla.firefox"))
    }
}

// MARK: - La comprobacion completa

/// `mayDelete` es lo ultimo antes de borrar: la ruta escrita, y la ruta a la
/// que lleva de verdad si alguna carpeta de por medio es un enlace.
final class MayDeleteTests: XCTestCase {

    private let home = NSHomeDirectory()
    private var sandbox: String!

    override func setUpWithError() throws {
        sandbox = home + "/Library/Caches/com.haumealabs.maccleaner.tests/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: sandbox)
    }

    /// Una lista de rutas que tienen que caer todas. Vive en un fichero para
    /// que anadir una sea anadir una linea.
    func testNingunaRutaPeligrosaPasa() throws {
        let corpus = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dangerous_paths.txt")
        let lines = try String(contentsOf: corpus, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: "$HOME", with: home) }
        XCTAssertGreaterThan(lines.count, 70, "el corpus parece incompleto")
        for path in lines {
            XCTAssertFalse(Engine.mayDelete(path), "paso: \(path)")
        }
    }

    func testLosCaracteresDeControlNoPasan() {
        XCTAssertFalse(Engine.isSafe(home + "/Library/Caches/a\nb"))
        XCTAssertFalse(Engine.isSafe(home + "/Library/Caches/a\u{0}b"))
        XCTAssertFalse(Engine.isSafe(home + "/Library/Caches/a\tb"))
        XCTAssertTrue(Engine.isSafe(home + "/Library/Caches/a b"))
    }

    /// Una carpeta de por medio que es un enlace al sistema: la ruta escrita
    /// parece una cache, pero lo que se borraria es /System.
    func testUnEnlaceDePorMedioHaciaElSistemaNoPasa() throws {
        let link = sandbox + "/sistema"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/System/Library")
        let through = link + "/CoreServices"
        XCTAssertTrue(Engine.isSafe(through), "escrita, parece del home")
        XCTAssertFalse(Engine.mayDelete(through), "resuelta, es /System")
    }

    /// Un enlace hacia el propio home deja la ruta en una carpeta de primer
    /// nivel, que tampoco se toca.
    func testUnEnlaceDePorMedioHaciaElHomeNoPasa() throws {
        let link = sandbox + "/casa"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home)
        XCTAssertFalse(Engine.mayDelete(link + "/Library"))
    }

    /// El enlace en si se puede borrar: lo que desaparece es el enlace, no a
    /// lo que apunta.
    func testElEnlaceEnSiSePuedeBorrar() throws {
        let link = sandbox + "/sistema"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/System/Library")
        XCTAssertTrue(Engine.mayDelete(link))

        let result = Engine.erase(paths: [link], scope: .contents, toTrash: false)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(FileSystem.exists(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/System/Library/CoreServices"))
    }

    /// Lo resuelto solo quita permiso: un enlace dentro de la propia cache
    /// sigue siendo la cache.
    func testUnEnlaceQueSeQuedaEnLaCachePasa() throws {
        let real = sandbox + "/real/dentro"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: sandbox + "/atajo",
                                                   withDestinationPath: sandbox + "/real")
        XCTAssertTrue(Engine.mayDelete(sandbox + "/atajo/dentro"))
    }

    /// Un disco externo si: quien se lleva ~/.gradle a otro disco quiere poder
    /// limpiarlo. Su raiz no.
    func testUnDiscoExternoValeSalvoSuRaiz() {
        XCTAssertTrue(Engine.isOnExternalVolume("/Volumes/External/gradle/caches"))
        XCTAssertTrue(Engine.isOnExternalVolume("/Volumes/External/x"))
        XCTAssertFalse(Engine.isOnExternalVolume("/Volumes/External"))
        XCTAssertFalse(Engine.isOnExternalVolume("/Volumes"))
        XCTAssertFalse(Engine.isOnExternalVolume("/Users/x/Volumes/a/b"))
    }

    /// Lo que ya no esta no se puede borrar mal: borrarlo es no hacer nada,
    /// y no es un error.
    func testLoQueYaNoEstaNoEsUnError() {
        let gone = sandbox + "/no-existe"
        let result = Engine.erase(paths: [gone], scope: .contents, toTrash: false)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.leftover[gone], 0)
    }
}

/// El historial de los asistentes es conversacion, no cache: no se ofrece
/// nunca, lo pida el patron que lo pida.
final class AgentHistoryTests: XCTestCase {

    func testElHistorialDeLosAsistentesEstaProtegido() {
        let home = NSHomeDirectory()
        for path in ["/.codex/sessions", "/.codex/sessions/2026/10/02/x.jsonl",
                     "/.codex/archived_sessions", "/.claude/projects/-Users-x-app"] {
            XCTAssertTrue(FileSystem.isProtected(home + path), path)
        }
        XCTAssertFalse(FileSystem.isProtected(home + "/.codex/cache"))
        XCTAssertFalse(FileSystem.isProtected(home + "/.claude/shell-snapshots"))
    }
}
