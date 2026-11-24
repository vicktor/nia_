#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Compatibility entry point: nia_ is now a native SwiftUI + Metal application.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/build-native-macos.sh" "$@"
