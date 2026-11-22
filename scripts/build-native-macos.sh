#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Este empaquetador requiere macOS y Xcode Command Line Tools." >&2
    exit 1
fi
command -v swiftc >/dev/null || { echo "Instala Xcode Command Line Tools (xcode-select --install)" >&2; exit 1; }
command -v cargo >/dev/null || { echo "Instala Rust desde rustup.rs" >&2; exit 1; }

# Build the self-contained local inference helper on macOS. Model weights are
# downloaded later in Preferences, never bundled with the application.
command -v cmake >/dev/null || { echo "Instala CMake (brew install cmake) para Nia AI Interno" >&2; exit 1; }
command -v git >/dev/null || { echo "Git es necesario para compilar el motor local" >&2; exit 1; }
ENGINE_SRC="$ROOT/.build/llama.cpp"
if [[ ! -d "$ENGINE_SRC/.git" ]]; then
    mkdir -p "$ROOT/.build"
    git clone --depth 1 --branch v1.0.0 https://github.com/ggml-org/llama.cpp.git "$ENGINE_SRC"
fi
# Nia only uses the JSON API. Do not build/download llama.cpp's browser UI.
# Remove UI assets from previous failed builds: some llama.cpp releases try to
# embed incomplete stale assets even with UI disabled.
rm -rf "$ENGINE_SRC/tools/ui/dist" "$ROOT/.build/llama-build/tools/ui/dist"
# CMake caches absolute paths: regenerate when this source tree is moved.
CMAKE_CACHE="$ROOT/.build/llama-build/CMakeCache.txt"
if [[ -f "$CMAKE_CACHE" ]]; then
    CACHED_SOURCE="$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$CMAKE_CACHE")"
    if [[ "$CACHED_SOURCE" != "$ENGINE_SRC" ]]; then
        echo "CMake cache from another directory; regenerating llama-build..."
        rm -rf "$ROOT/.build/llama-build"
    fi
fi
cmake -S "$ENGINE_SRC" -B "$ROOT/.build/llama-build" \
    -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
cmake --build "$ROOT/.build/llama-build" --target llama-server --config Release -j 4
cargo build --release --lib --bin nia-backup
# Build in staging: never leave a half-built dist/nia_.app behind.
mkdir -p "$ROOT/dist"
FINAL_APP="$ROOT/dist/nia_.app"
APP="$(mktemp -d "$ROOT/dist/.nia-build.XXXXXX")/nia_.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cleanup() { rm -rf "$(dirname "$APP")"; }
trap cleanup EXIT

cp target/release/libnia_core.dylib "$APP/Contents/Frameworks/"
install_name_tool -id '@rpath/libnia_core.dylib' "$APP/Contents/Frameworks/libnia_core.dylib"
swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macosx14.0" \
    -import-objc-header native/include/NiaBridge.h \
    native/Sources/NiaApp.swift native/Sources/NiaTerminalView.swift native/Sources/NiaAI.swift native/Sources/NiaAIExecutionPolicy.swift native/Sources/NiaInternalAI.swift \
    -L target/release -lnia_core \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -framework AppKit -framework SwiftUI -framework Metal -framework MetalKit -framework CoreText \
    -o "$APP/Contents/MacOS/nia"
install -m 755 target/release/nia-backup "$APP/Contents/MacOS/nia-backup"
install -m 755 "$ROOT/.build/llama-build/bin/llama-server" "$APP/Contents/MacOS/nia-llama-server"
# Static build must not depend on unbundled Homebrew llama/ggml dylibs.
if otool -L "$APP/Contents/MacOS/nia-llama-server" | grep -Eq '/(opt/homebrew|usr/local)/(opt|lib)/.*(llama|ggml)'; then
    echo "ERROR: llama-server contiene dependencias externas no empaquetadas" >&2
    exit 1
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>nia_</string>
  <key>CFBundleDisplayName</key><string>nia_</string>
  <!-- Keep the existing bundle ID so existing preferences and Keychain entries remain accessible. -->
  <key>CFBundleIdentifier</key><string>dev.nia.terminal</string>
  <key>CFBundleExecutable</key><string>nia</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>nia_.icns</string>
  <key>CFBundleShortVersionString</key><string>0.6.4</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST
ICONSET="$(mktemp -d)/nia_.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$ROOT/assets/nia-icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    twice=$((size * 2))
    sips -s format png -z "$twice" "$twice" "$ROOT/assets/nia-icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/nia_.icns"
rm -rf "$(dirname "$ICONSET")"
plutil -lint "$APP/Contents/Info.plist"
# Inside-out signing: first the Rust dylib, then the app bundle.
codesign --force --sign - "$APP/Contents/Frameworks/libnia_core.dylib"
codesign --force --sign - "$APP/Contents/MacOS/nia-backup"
codesign --force --sign - "$APP/Contents/MacOS/nia-llama-server"
codesign --force --sign - "$APP"
# Make sure the built bundle is launchable before publishing it.
test -x "$APP/Contents/MacOS/nia"
test -f "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

# Preserve the previous working app until the replacement is complete.
OLD_APP="$ROOT/dist/.nia_-previous.app"
rm -rf "$OLD_APP"
if [[ -d "$FINAL_APP" ]]; then mv "$FINAL_APP" "$OLD_APP"; fi
if mv "$APP" "$FINAL_APP"; then
    rm -rf "$OLD_APP"
else
    [[ ! -d "$OLD_APP" ]] || mv "$OLD_APP" "$FINAL_APP"
    echo "ERROR: no se pudo publicar nia_.app; la versión anterior se ha conservado." >&2
    exit 1
fi
echo "nia_ nativa: $FINAL_APP"
echo "Ejecuta: open '$FINAL_APP'"
