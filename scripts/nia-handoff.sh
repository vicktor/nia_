#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Nia encrypted, one-way workspace handoff. NOT live bidirectional sync.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="${NIA_BACKUP_BIN:-$ROOT/target/release/nia-backup}"
if [[ ! -x "$BACKUP" ]]; then
  echo "Falta nia-backup. Ejecuta ./scripts/build-native-macos.sh primero." >&2; exit 1
fi
case "${1:-}" in
  push)
    echo "Creando snapshot cifrado del workspace local..."
    exec "$BACKUP" backup
    ;;
  pull)
    DEST="${2:-$HOME/Nia-Handoff-$(date +%Y%m%d-%H%M%S)}"
    if [[ -e "$DEST" ]]; then
      echo "El destino ya existe: $DEST" >&2; exit 1
    fi
    echo "Recuperando a una carpeta independiente: $DEST"
    "$BACKUP" restore "$DEST"
    echo "Estado recuperado en $DEST/state. CIERRA Nia antes de importar."
    echo "No se han reemplazado tus sesiones locales ni mezclado bases de datos."
    ;;
  snapshots) exec "$BACKUP" snapshots ;;
  check) exec "$BACKUP" check ;;
  *) echo "Uso: $0 push | pull [directorio-vacio-nuevo] | snapshots | check" >&2; exit 2 ;;
esac
