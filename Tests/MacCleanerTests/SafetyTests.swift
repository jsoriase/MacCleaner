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
}
