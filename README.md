# MacCleaner

Limpiador de cachés de desarrollo para macOS. Nativo, sin dependencias, 1 MB.

![Swift](https://img.shields.io/badge/Swift-6-orange) ![macOS](https://img.shields.io/badge/macOS-13%2B-blue)

## Qué hace

Localiza y mide las cachés que dejan las herramientas de desarrollo —Xcode,
Gradle, Android Studio, npm, Cargo, Homebrew y unas cuantas más— y te deja
borrar las que quieras. **40 categorías** repartidas en 6 grupos.

## Cómo se usa

1. **Analizar.** Solo mide, no borra nada.
2. **Marcar.** Al abrir la app no hay nada seleccionado. Los tres botones de la
   barra superior marcan de golpe todas las filas de un nivel de riesgo, y son
   acumulativos: `Seguras` + `Se regeneran` deja las dos tandas marcadas.
   Cada botón lleva su propio total, así que ves lo que ganas antes de decidir.
   También puedes marcar filas sueltas, o usar los enlaces `Todo` / `Nada` que
   aparecen al pasar el ratón sobre una cabecera de grupo.
3. **Limpiar.** Un diálogo dice exactamente cuánto y qué, y avisa aparte de las
   categorías marcadas como «Cuidado».

La selección **no se recuerda entre sesiones**: cada vez que abres la app
empiezas de cero, para que borrar sea siempre una decisión deliberada y no algo
heredado de la vez anterior.

## Idiomas

La app se traduce a **43 idiomas** y toma el del sistema automáticamente, con
respaldo en inglés si el tuyo no está. Cubre el idioma principal de cada país
de Europa, más las lenguas cooficiales de España y los idiomas más hablados del
mundo.

**Europa:** albanés (`sq`), alemán (`de`), belaruso (`be`), bosnio (`bs`),
búlgaro (`bg`), croata (`hr`), checo (`cs`), danés (`da`), eslovaco (`sk`),
esloveno (`sl`), estonio (`et`), finés (`fi`), francés (`fr`), griego (`el`),
húngaro (`hu`), inglés (`en`), irlandés (`ga`), islandés (`is`), italiano
(`it`), letón (`lv`), lituano (`lt`), luxemburgués (`lb`), macedonio (`mk`),
maltés (`mt`), neerlandés (`nl`), noruego bokmål (`nb`), polaco (`pl`),
portugués de Portugal (`pt-PT`), rumano (`ro`), ruso (`ru`), serbio (`sr`),
sueco (`sv`), turco (`tr`), ucraniano (`uk`).

**España:** español (`es`), catalán (`ca`), gallego (`gl`), euskera (`eu`).

**Resto del mundo:** árabe (`ar`), chino simplificado (`zh-Hans`), hindi (`hi`),
japonés (`ja`), portugués de Brasil (`pt-BR`).

Los textos viven en `Resources/Localizations/<idioma>.lproj/Localizable.strings`
y `build.sh` los copia dentro del `.app`. El nombre y la descripción de cada
categoría se derivan de su id (`target.gradle.caches.name`), así que no pueden
desincronizarse del catálogo. Seis claves —nombres propios como
`Xcode DerivedData` y rutas como `~/.npm/_cacache`— son idénticas en todos los
idiomas y se rellenan solas.

En árabe la interfaz se refleja de derecha a izquierda. macOS no deduce eso solo
en SwiftUI, así que la dirección se fija a partir de la localización que el
bundle elige (ver `appLayoutDirection`).

Para probar un idioma sin cambiar el del sistema:

```bash
open MacCleaner.app --args -AppleLanguages "(ja)"
```

### Calidad de las traducciones

Están hechas por un modelo de lenguaje, no por hablantes nativos, y el nivel no
es uniforme. Las lenguas romances y germánicas son sólidas; el maltés, el
luxemburgués, el irlandés, el euskera y el albanés merecen una revisión antes de
distribuir la app en serio, sobre todo en las frases que avisan de borrados
permanentes. El bosnio está derivado del croata con ajustes léxicos, no
traducido de forma independiente.

Cinco tests protegen las traducciones: que los 43 idiomas tengan exactamente las
mismas claves, que el `Info.plist` declare justo los que hay en disco, que
ninguna fila del catálogo se quede sin nombre ni nota, que ningún texto esté
vacío, y que los marcadores de formato (`%@`, `%d`) coincidan entre idiomas —
un `%d` convertido en `%@` hace que `String(format:)` lea basura de la pila.

## Compilar

```bash
./build.sh
```

Genera `MacCleaner.app` (universal, arm64 + x86_64). Para instalarlo:

```bash
cp -R MacCleaner.app /Applications/
```

Al abrirlo por primera vez macOS avisará de que no está firmado por un
desarrollador identificado: clic derecho › Abrir, o Ajustes › Privacidad y
seguridad › Abrir igualmente.

## Por qué Swift

El requisito era el menor consumo de RAM posible. Medido en este Mac:

| | Memoria |
|---|---|
| En reposo | **38 MB** |
| Pico analizando 49 GB / ~500 000 archivos | **75 MB** |

Un limpiador equivalente en Electron ronda los 300–400 MB. Swift compila a
binario nativo y usa las mismas bibliotecas del sistema que ya están cargadas
en memoria, así que el coste marginal es mínimo.

El recorrido de directorios usa `fts(3)` y `glob(3)` directamente en lugar de
`FileManager.enumerator`: son C puro, no crean objetos intermedios y mantienen
la memoria plana sin importar el tamaño del árbol.

## Niveles de riesgo

Cada categoría lleva una etiqueta, y hay un botón por nivel:

- **Seguro** — se regenera solo, sin efectos secundarios.
- **Se regenera** — seguro, pero la siguiente compilación irá más lenta.
- **Cuidado** — hay que volver a descargar cosas o pierdes datos útiles
  (Archives de Xcode, repositorio de Maven, copias de iOS, papelera…).

Los tres niveles cubren el catálogo entero: no hay ninguna fila que quede fuera
de los botones. Hay un test que lo comprueba.

## Seguridad

Tres capas, todas cubiertas por tests:

1. **Fuera del home no se toca nada.** Ni `/`, ni `/System`, ni otros volúmenes.
2. **Carpetas de primer nivel del home protegidas**: `Library`, `Documents`,
   `Desktop`, `Downloads`, `Pictures`, `Music`, `Movies`…
3. **Rutas protegidas por TCC ignoradas por completo** (`com.apple.Music`,
   `com.apple.Photos`, `MobileSync`…). Con solo *leerlas* macOS lanza un
   diálogo de permisos que congelaría el análisis, así que MacCleaner ni las
   mide ni las borra.

`Mover a la Papelera` deja el borrado reversible, a cambio de que el espacio
no se libere hasta vaciarla.

```bash
swift test
```

## Estructura

```
Sources/MacCleaner/
  App/MacCleanerApp.swift    punto de entrada
  Core/FileSystem.swift      glob, fts, borrado, rutas protegidas
  Core/Catalog.swift         las 40 categorías y sus rutas
  Core/Engine.swift          análisis en paralelo y limpieza
  UI/ContentView.swift       ventana principal
  UI/Components.swift        filas, cabeceras, distintivos
```

Para añadir una categoría basta con un `Target` más en `Catalog.swift`.
