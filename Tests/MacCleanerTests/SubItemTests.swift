import XCTest
@testable import MacCleaner

/// La logica de las filas desplegables vive entera en `Row`, asi que se puede
/// probar sin tocar el disco.
final class SubItemTests: XCTestCase {

    private func makeRow(_ items: [(String, Int64, Bool)],
                         selected: Bool = false,
                         expandable: Bool = true) -> Row {
        let target = Target(id: "gradle.caches",
                            group: .jvm, risk: .rebuild, scope: .contents,
                            patterns: ["~/.gradle/caches"], expandable: expandable)
        var row = Row(target: target, selected: selected)
        row.paths = [NSHomeDirectory() + "/.gradle/caches"]
        row.items = items.map { name, bytes, on in
            SubItem(path: NSHomeDirectory() + "/.gradle/caches/" + name,
                    name: name,
                    usage: FileSystem.Usage(bytes: bytes, files: 1),
                    selected: on)
        }
        return row
    }

    // MARK: - Estado de la casilla

    func testSinNadaMarcadoLaCasillaEstaVacia() {
        let row = makeRow([("9.1.0", 517, false), ("9.4.1", 766, false)])
        XCTAssertEqual(row.checkState, .off)
        XCTAssertFalse(row.anySelected)
    }

    func testConTodoMarcadoLaCasillaEstaLlena() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, true)])
        XCTAssertEqual(row.checkState, .on)
        XCTAssertTrue(row.anySelected)
    }

    func testConParteMarcadaLaCasillaQuedaAMedias() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, false)])
        XCTAssertEqual(row.checkState, .mixed)
        XCTAssertTrue(row.anySelected)
    }

    // MARK: - Tamano

    func testSoloCuentaElTamanoDeLoMarcado() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, false), ("modules-2", 748, false)])
        XCTAssertEqual(row.selectedBytes, 517, "solo la version marcada")
    }

    func testUnaFilaNormalCuentaSuTotalSiEstaMarcada() {
        var row = makeRow([], selected: true, expandable: false)
        row.usage = FileSystem.Usage(bytes: 1234, files: 9)
        XCTAssertFalse(row.hasItems)
        XCTAssertEqual(row.selectedBytes, 1234)
    }

    // MARK: - Que se borra

    func testSeBorranSoloLasSubcarpetasMarcadas() {
        let row = makeRow([("9.1.0", 517, true), ("9.4.1", 766, false), ("modules-2", 748, true)])
        let (paths, scope) = row.victims

        XCTAssertEqual(scope, .item, "cada subcarpeta se borra entera")
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/9.1.0") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("/modules-2") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("/9.4.1") }, "la version sin marcar se queda")
    }

    func testUnaFilaNormalSigueBorrandoSuContenido() {
        var row = makeRow([], selected: true, expandable: false)
        row.usage = FileSystem.Usage(bytes: 10, files: 1)
        let (paths, scope) = row.victims

        XCTAssertEqual(scope, .contents)
        XCTAssertEqual(paths, row.paths)
    }

    /// Las rutas de las subcarpetas tienen que pasar la red de seguridad,
    /// igual que las de las filas normales.
    func testLasSubcarpetasSonRutasSeguras() {
        let row = makeRow([("9.1.0", 517, true), ("modules-2", 748, true)])
        for path in row.victims.paths {
            XCTAssertTrue(Engine.isSafe(path), path)
            XCTAssertFalse(FileSystem.isProtected(path), path)
        }
    }

    // MARK: - Catalogo

    func testSoloLasFilasDeGradleSeDespliegan() {
        let expandables = Catalog.targets.filter(\.expandable).map(\.id)
        XCTAssertEqual(Set(expandables), ["gradle.caches", "gradle.wrapper"])
    }

    func testLasFilasDesplegablesBorranPorContenido() {
        // Sus hijos son justo las victimas de un borrado .contents, asi que el
        // desglose y el borrado normal tienen que coincidir.
        for target in Catalog.targets where target.expandable {
            XCTAssertEqual(target.scope, .contents, target.id)
        }
    }
}
