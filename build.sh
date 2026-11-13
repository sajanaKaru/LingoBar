#!/bin/bash
set -euo pipefail

APP_NAME="LingoBar"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building ${APP_NAME} binary with swiftc..."
swiftc -parse-as-library main.swift KeychainHelper.swift SettingsView.swift -o "${APP_NAME}"

echo "==> Preparing bundle directory structure..."
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "==> Installing binary into app bundle..."
cp -f "${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

if [ -f "Info.plist" ]; then
    cp -f Info.plist "${CONTENTS_DIR}/Info.plist"
elif [ -f "${CONTENTS_DIR}/Info.plist" ]; then
    echo "==> Retaining existing ${CONTENTS_DIR}/Info.plist"
fi

if [ -f "Resources/AppIcon.icns" ]; then
    cp -f Resources/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
fi

echo "==> Signing ${APP_BUNDLE} with designated requirement..."
codesign --force --deep -s - -i "com.lingobar.macos" --requirements '=designated => identifier "com.lingobar.macos"' "${APP_BUNDLE}"

echo "==> Build and packaging complete: ${APP_BUNDLE}"
