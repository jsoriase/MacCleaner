#!/bin/bash
# Compila MacCleaner y genera MacCleaner.app en la raiz del proyecto.
# Uso: ./build.sh [arm64|x86_64]   (sin parametro: universal arm64+x86_64)
set -euo pipefail
cd "$(dirname "$0")"

APP="MacCleaner.app"

case "${1:-universal}" in
    universal) ARCH_ARGS=(--arch arm64 --arch x86_64); ARCH_DESC="universal arm64+x86_64" ;;
    arm64)     ARCH_ARGS=(--arch arm64);                ARCH_DESC="arm64" ;;
    x86_64)    ARCH_ARGS=(--arch x86_64);               ARCH_DESC="x86_64" ;;
    *)
        echo "Arquitectura desconocida: $1" >&2
        echo "Uso: $0 [arm64|x86_64]   (sin parametro: universal)" >&2
        exit 1
        ;;
esac

echo "==> Compilando (release, $ARCH_DESC)"
swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)"

echo "==> Empaquetando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacCleaner" "$APP/Contents/MacOS/MacCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Localizations/*.lproj "$APP/Contents/Resources/"

echo "==> Firmando (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo
echo "Listo: $(pwd)/$APP"
echo "Binario: $(du -h "$APP/Contents/MacOS/MacCleaner" | cut -f1) ($(lipo -archs "$APP/Contents/MacOS/MacCleaner"))"
echo "Idiomas: $(ls -d "$APP/Contents/Resources"/*.lproj | wc -l | tr -d ' ')"
echo
echo "Abrir con:  open $APP"
echo "Instalar:   cp -R $APP /Applications/"
