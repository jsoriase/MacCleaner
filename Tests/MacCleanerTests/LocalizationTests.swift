import XCTest
import SwiftUI
@testable import MacCleaner

/// Los textos viven fuera del binario, asi que nada impide que una clave nueva
/// se quede sin traducir. Estos tests cierran ese agujero.
final class LocalizationTests: XCTestCase {

    /// Los idiomas no se listan a mano: se descubren en disco, para que anadir
    /// uno nuevo no dependa de acordarse de tocar este fichero.
    private lazy var languages: [String] = {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: localizationsDirectory.path)) ?? []
        return contents
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(6)) }
            .sorted()
    }()

    /// Raiz del repositorio, deducida de la ubicacion de este fichero.
    private var localizationsDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/MacCleanerTests/este.swift
            .deletingLastPathComponent()          // .../Tests/MacCleanerTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // raiz
            .appendingPathComponent("Resources/Localizations")
    }

    /// Usa el parser de plists de Foundation: si un `.strings` tiene un error
    /// de sintaxis devuelve nil y el test cae, que es justo lo que se quiere.
    private func strings(for language: String) throws -> [String: String] {
        let url = localizationsDirectory
            .appendingPathComponent("\(language).lproj/Localizable.strings")
        let parsed = NSDictionary(contentsOf: url) as? [String: String]
        return try XCTUnwrap(parsed, "no se pudo leer \(language).lproj/Localizable.strings")
    }

    // MARK: - Cobertura

    func testTodosLosIdiomasTienenContenido() throws {
        XCTAssertGreaterThanOrEqual(languages.count, 10, "faltan idiomas en disco")
        for language in languages {
            let table = try strings(for: language)
            XCTAssertFalse(table.isEmpty, language)
        }
    }

    /// Si un idioma esta en disco pero no en el Info.plist, macOS no lo ofrece;
    /// si esta en el plist pero no en disco, la app promete lo que no cumple.
    func testElInfoPlistDeclaraExactamenteLosIdiomasQueExisten() throws {
        let plist = localizationsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let contents = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let declared = try XCTUnwrap(contents["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(Set(declared), Set(languages),
                       "en el plist y no en disco: \(Set(declared).subtracting(languages).sorted()); "
                       + "en disco y no en el plist: \(Set(languages).subtracting(declared).sorted())")
    }

    func testTodosLosIdiomasTienenLasMismasClaves() throws {
        let reference = Set(try strings(for: "en").keys)
        XCTAssertGreaterThan(reference.count, 100, "el ingles parece incompleto")

        for language in languages where language != "en" {
            let keys = Set(try strings(for: language).keys)
            XCTAssertTrue(keys == reference,
                          "\(language): faltan \(reference.subtracting(keys).sorted()), "
                          + "sobran \(keys.subtracting(reference).sorted())")
        }
    }

    func testCadaFilaDelCatalogoTieneNombreYNota() throws {
        for language in languages {
            let table = try strings(for: language)
            for target in Catalog.targets {
                XCTAssertNotNil(table["target.\(target.id).name"],
                                "\(language) sin nombre para \(target.id)")
                XCTAssertNotNil(table["target.\(target.id).note"],
                                "\(language) sin nota para \(target.id)")
            }
        }
    }

    func testCadaCategoriaYCadaRiesgoEstanTraducidos() throws {
        for language in languages {
            let table = try strings(for: language)
            for category in Category.allCases {
                XCTAssertNotNil(table["category.\(category.rawValue)"],
                                "\(language) sin \(category.rawValue)")
            }
            for risk in Risk.allCases {
                for suffix in ["label", "plural", "help"] {
                    XCTAssertNotNil(table["risk.\(risk.rawValue).\(suffix)"],
                                    "\(language) sin risk.\(risk.rawValue).\(suffix)")
                }
            }
        }
    }

    func testNingunTextoEstaVacio() throws {
        for language in languages {
            for (key, value) in try strings(for: language) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(language): \(key) esta vacio")
            }
        }
    }

    // MARK: - Marcadores de formato

    /// Si un idioma se deja un `%d` o lo cambia por `%@`, `String(format:)`
    /// lee basura de la pila. Es el fallo clasico de localizacion.
    func testLosMarcadoresDeFormatoCoincidenEntreIdiomas() throws {
        let pattern = try NSRegularExpression(pattern: "%[0-9.]*[@dfs]")
        func specifiers(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: range)
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
                .sorted()
        }

        let english = try strings(for: "en")
        for language in languages where language != "en" {
            let table = try strings(for: language)
            for (key, reference) in english {
                guard let translated = table[key] else { continue }
                XCTAssertEqual(specifiers(translated), specifiers(reference),
                               "\(language): \(key) no cuadra con el ingles")
            }
        }
    }
}

// MARK: - Direccion de escritura

final class LayoutDirectionTests: XCTestCase {

    func testLosIdiomasDeDerechaAIzquierdaSeDetectan() {
        XCTAssertEqual(layoutDirection(forLanguageCode: "ar"), .rightToLeft)
        XCTAssertEqual(layoutDirection(forLanguageCode: "he"), .rightToLeft)
        XCTAssertEqual(layoutDirection(forLanguageCode: "fa"), .rightToLeft)
    }

    func testElRestoSeQuedaDeIzquierdaADerecha() {
        for code in ["en", "es", "fr", "de", "ru", "ja", "hi", "pt-BR", "zh-Hans"] {
            XCTAssertEqual(layoutDirection(forLanguageCode: code), .leftToRight, code)
        }
    }

    func testFuncionaConVariantesRegionales() {
        XCTAssertEqual(layoutDirection(forLanguageCode: "ar-EG"), .rightToLeft)
        XCTAssertEqual(layoutDirection(forLanguageCode: "es-ES"), .leftToRight)
    }
}
