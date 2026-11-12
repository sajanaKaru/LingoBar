#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="LingoBar"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Compiling ${APP_NAME} from main.swift..."
swiftc -parse-as-library main.swift -o "${APP_NAME}"

echo "==> Constructing ${APP_BUNDLE} bundle structure..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "==> Installing binary, Info.plist, and AppIcon.icns..."
cp -f "${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp -f Info.plist "${CONTENTS_DIR}/Info.plist"

if [ -f "Resources/AppIcon.icns" ]; then
    cp -f "Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

echo "==> Signing ${APP_BUNDLE} with designated requirement..."
codesign --force --deep -s - -i "com.lingobar.macos" --requirements '=designated => identifier "com.lingobar.macos"' "${APP_BUNDLE}"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "==> Build and packaging completed successfully: ${APP_BUNDLE}"
