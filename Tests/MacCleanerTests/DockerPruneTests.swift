import XCTest
@testable import MacCleaner

/// La fila de Docker ensenaba lo que pesa `Docker.raw` —5,6 GB— y el prune
/// liberaba 8 KB: dentro estaban las imagenes etiquetadas y los volumenes, que
/// no toca. Estos tests fijan que se ofrece solo lo que el prune se lleva, y
/// que lo liberado se espera a que el disco lo devuelva.
final class DockerPruneTests: XCTestCase {

    // MARK: - Tamanos de docker

    func testLosTamanosSonDecimales() {
        XCTAssertEqual(DockerPrune.bytes("0B"), 0)
        XCTAssertEqual(DockerPrune.bytes("638.3kB"), 638_300)
        XCTAssertEqual(DockerPrune.bytes("81.11MB"), 81_110_000)
        XCTAssertEqual(DockerPrune.bytes("2.963GB"), 2_963_000_000)
        XCTAssertEqual(DockerPrune.bytes("1.5TB"), 1_500_000_000_000)
    }

    /// Una imagen que comparte mas de lo que ocupa sale en negativo y en
    /// notacion cientifica. No libera nada.
    func testLoNegativoNoCuenta() {
        XCTAssertEqual(DockerPrune.bytes("-4.91e+07B"), 0)
        XCTAssertEqual(DockerPrune.bytes("4.91e+07B"), 49_100_000)
    }

    func testVaLaPrimeraCifra() {
        XCTAssertEqual(DockerPrune.bytes("200MB (virtual 611MB)"), 200_000_000)
    }

    func testLoQueNoEsUnTamanoNoSeInventa() {
        XCTAssertNil(DockerPrune.bytes("N/A"))
        XCTAssertNil(DockerPrune.bytes(""))
        XCTAssertNil(DockerPrune.bytes("MB"))
    }

    // MARK: - Lo que se lleva el prune

    private let dangling = "sha256:" + String(repeating: "d", count: 64)
    private let tagged = "sha256:" + String(repeating: "t", count: 64)

    private func usage(images: [[String: String]] = [],
                       containers: [[String: String]] = [],
                       cache: [[String: String]] = [],
                       volumes: [[String: String]] = []) -> Data {
        let root: [String: Any] = ["Images": images, "Containers": containers,
                                   "BuildCache": cache, "Volumes": volumes]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func prunable(_ data: Data) -> Int64? {
        DockerPrune.prunable(usage: data, dangling: [dangling])
    }

    /// El caso que se denuncio: imagenes etiquetadas, volumenes y cache
    /// compartida ocupan gigas, y el prune no se lleva nada de eso.
    func testLoQueElPruneNoTocaNoSeOfrece() {
        let data = usage(
            images: [["ID": tagged, "UniqueSize": "194MB", "Containers": "0"]],
            cache: [["CacheType": "regular", "InUse": "false", "Shared": "true", "Size": "2.18GB"],
                    ["CacheType": "frontend", "InUse": "false", "Shared": "false", "Size": "34.3MB"]],
            volumes: [["Name": "db", "Size": "421.5MB", "Links": "0"]])
        XCTAssertEqual(prunable(data), 0)
    }

    func testContenedoresParadosSiArrancadosNo() {
        let data = usage(containers: [
            ["State": "exited", "Size": "200MB"],
            ["State": "created", "Size": "1MB"],
            ["State": "dead", "Size": "2MB"],
            ["State": "running", "Size": "500MB"],
            ["State": "paused", "Size": "500MB"],
            ["State": "restarting", "Size": "500MB"],
        ])
        XCTAssertEqual(prunable(data), 203_000_000)
    }

    /// De una colgante, solo lo suyo: lo que comparte con otra imagen sigue
    /// ahi despues. Una con contenedor es la version vieja que sigue corriendo
    /// tras reconstruir la etiqueta, y esa no se la lleva.
    func testImagenesColgantesSinContenedor() {
        let other = "sha256:" + String(repeating: "e", count: 64)
        let data = usage(images: [
            ["ID": dangling, "UniqueSize": "58.74MB", "Size": "411MB", "Containers": "0"],
            ["ID": other, "UniqueSize": "100MB", "Containers": "0"],
        ])
        XCTAssertEqual(prunable(data), 58_740_000, "solo cuenta la que Docker da por colgante")

        let running = usage(images: [["ID": dangling, "UniqueSize": "58.74MB", "Containers": "1"]])
        XCTAssertEqual(prunable(running), 0)
    }

    func testCacheSinUsarNiCompartir() {
        let data = usage(cache: [
            ["CacheType": "regular", "InUse": "false", "Shared": "false", "Size": "10MB"],
            ["CacheType": "exec.cachemount", "InUse": "false", "Shared": "false", "Size": "5MB"],
            ["CacheType": "regular", "InUse": "true", "Shared": "false", "Size": "300MB"],
            ["CacheType": "regular", "InUse": "false", "Shared": "true", "Size": "300MB"],
            ["CacheType": "internal", "InUse": "false", "Shared": "false", "Size": "300MB"],
        ])
        XCTAssertEqual(prunable(data), 15_000_000)
    }

    func testSinJSONNoHayCifra() {
        XCTAssertNil(DockerPrune.prunable(usage: Data("Cannot connect".utf8), dangling: []))
        XCTAssertNil(DockerPrune.prunable(usage: Data("[]".utf8), dangling: []))
    }

    // MARK: - Esperar al disco

    /// Lecturas de `Docker.raw` una tras otra: la ultima se repite.
    private func readings(_ values: [Int64]) -> () -> Int64 {
        var queue = values
        return { queue.count > 1 ? queue.removeFirst() : queue[0] }
    }

    /// El caso de la prueba: el disco no baja hasta varios segundos despues.
    func testSeEsperaAQueElDiscoDevuelvaElHueco() {
        var pauses = 0
        let shrunk = DockerPrune.shrink(from: 1_000, expecting: 200,
                                        pause: { pauses += 1 },
                                        measure: readings([1_000, 1_000, 1_000, 1_000, 800]))
        XCTAssertEqual(shrunk, 200)
        XCTAssertEqual(pauses, 4)
    }

    /// Lo que paso en la prueba con el Docker de verdad: al acabar el prune el
    /// fichero baja 8 KB de metadatos y se queda quieto hasta que llega la
    /// tanda buena. Esos 8 KB no pueden cortar la espera.
    func testUnasMigajasNoCortanLaEspera() {
        let shrunk = DockerPrune.shrink(from: 1_000_000, expecting: 200_000,
                                        pause: {},
                                        measure: readings([999_992, 999_992, 999_992, 999_992,
                                                           999_992, 999_992, 800_000]))
        XCTAssertEqual(shrunk, 200_000)
    }

    func testSinNadaQueEsperarNoSeEspera() {
        var pauses = 0
        let shrunk = DockerPrune.shrink(from: 1_000, expecting: 0,
                                        pause: { pauses += 1 }, measure: readings([1_000]))
        XCTAssertEqual(shrunk, 0)
        XCTAssertEqual(pauses, 0)
    }

    /// Si el disco no devuelve nada, se rinde y lo dice: no se da por liberado.
    func testSiNoBajaSeRinde() {
        let shrunk = DockerPrune.shrink(from: 1_000, expecting: 500, rounds: 5,
                                        pause: {}, measure: readings([1_000]))
        XCTAssertEqual(shrunk, 0)
    }

    /// Bajo algo menos de lo esperado y se quedo quieto: no hace falta agotar
    /// la espera.
    func testSiDejaDeMoverseNoSeAlarga() {
        var pauses = 0
        let shrunk = DockerPrune.shrink(from: 1_000, expecting: 500,
                                        pause: { pauses += 1 },
                                        measure: readings([1_000, 700]))
        XCTAssertEqual(shrunk, 300)
        XCTAssertEqual(pauses, 4, "una para verlo bajar y tres quieto")
    }

    func testDetenerCortaLaEspera() {
        let shrunk = DockerPrune.shrink(from: 1_000, expecting: 500,
                                        isCancelled: { true },
                                        pause: { XCTFail("no deberia esperar") },
                                        measure: readings([1_000]))
        XCTAssertEqual(shrunk, 0)
    }

    // MARK: - Limpieza

    /// Sin `docker` en el Mac no se ha liberado nada: lo ofrecido sigue ahi.
    func testSinDockerNoSeDaNadaPorLiberado() throws {
        try XCTSkipIf(Tools.locate("docker") != nil, "con docker instalado lanzaria un prune de verdad")
        let path = NSHomeDirectory() + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        let result = Engine.reclaim(.docker, paths: [path],
                                    records: [path: Row.Record(bytes: 1_000, identity: nil)])
        XCTAssertEqual(result.leftover[path], 1_000)
        XCTAssertEqual(result.errors.count, 1)
    }
}
