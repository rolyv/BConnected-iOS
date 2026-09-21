#!/bin/bash
# Compile the real app/extension graph without producing a runnable or signed messenger.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to the reviewed Xcode.app/Contents/Developer}"
python3 Scripts/bconnected/verify_libsignal.py .build/bconnected-libsignal --platform iphonesimulator
exec xcodebuild -workspace Signal.xcworkspace -scheme Signal -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/CompileValidation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  BCONNECTED_COMPILE_VALIDATION=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG BCONNECTED_COMPILE_VALIDATION BCONNECTED_OWNED_LIBSIGNAL' \
  build
