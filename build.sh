#!/bin/bash
# Compila MacCleaner y genera MacCleaner.app en la raiz del proyecto.
set -euo pipefail
cd "$(dirname "$0")"

APP="MacCleaner.app"

echo "==> Compilando (release, universal arm64+x86_64)"
swift build -c release --arch arm64 --arch x86_64

echo "==> Empaquetando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/MacCleaner "$APP/Contents/MacOS/MacCleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Localizations/*.lproj "$APP/Contents/Resources/"

echo "==> Firmando (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo
echo "Listo: $(pwd)/$APP"
echo "Binario: $(du -h "$APP/Contents/MacOS/MacCleaner" | cut -f1)"
echo "Idiomas: $(ls -d "$APP/Contents/Resources"/*.lproj | wc -l | tr -d ' ')"
echo
echo "Abrir con:  open $APP"
echo "Instalar:   cp -R $APP /Applications/"
