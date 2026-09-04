import Foundation
import SwiftUI

/// Textos traducidos. Viven en `MacCleaner.app/Contents/Resources/<idioma>.lproj/
/// Localizable.strings` y macOS elige el fichero segun el idioma del sistema,
/// cayendo a ingles si el del usuario no esta disponible.
///
/// Fuera del bundle (por ejemplo en `swift test`) no hay traducciones y se
/// devuelve la propia clave, que es justo lo que un test necesita ver.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// Version con argumentos: `L("footer.selected", 18)`.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .main, comment: ""),
           locale: .current,
           arguments: arguments)
}

/// Direccion de escritura de un idioma. Se separa del bundle para poder probarla.
func layoutDirection(forLanguageCode code: String) -> LayoutDirection {
    let base = code.split(separator: "-").first.map(String.init) ?? code
    return Locale.Language(identifier: base).characterDirection == .rightToLeft
        ? .rightToLeft
        : .leftToRight
}

/// Direccion que corresponde al idioma que el bundle ha elegido realmente.
///
/// Hace falta ponerla a mano: en macOS, SwiftUI no la deduce de la localizacion
/// activa, asi que en arabe los textos salian bien pero la interfaz seguia
/// ordenada de izquierda a derecha.
var appLayoutDirection: LayoutDirection {
    layoutDirection(forLanguageCode: Bundle.main.preferredLocalizations.first ?? "en")
}
