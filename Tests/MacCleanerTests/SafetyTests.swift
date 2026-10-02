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
