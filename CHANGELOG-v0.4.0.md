# Nia 0.4.0 — Primer renderer Metal

## Implementado
- Sustituida `NSTextView` por `MTKView` en la aplicación nativa.
- Rust expone cuadrícula VT100 con contenido, colores ANSI indexados y RGB, estilo negrita/tenue/cursiva/subrayado/inverso y marcadores de caracteres anchos.
- Pipeline Metal para rectángulos de fondo, glifos y cursor.
- Atlas de glifos CoreText de tamaño fijo, cacheado por fuente/tamaño, subido a GPU cuando incorpora nuevos glifos.
- Presentación por cambios; no hay bucle a 60/120 FPS. Temporizador de cursor 550 ms.
- Selección con ratón, copia automática opcional, Cmd+C, Cmd+V y Tab hacia el PTY.
- Dimensiones del PTY dependientes de la ventana y del escalado Retina.
- Se conservan SQLite, nombres y colores de sesión, Zsh, directorios y entorno virtual registrados.

## Limitaciones conocidas de esta primera iteración
- No se ha probado en un Mac real y no debe considerarse un emulador completo validado.
- La selección opera sobre el grid visible; falta scrollback interactivo histórico, selección por palabra y soporte de ratón para TUI.
- Comportamientos de teclado especiales (teclado internacional/IME, mode application cursor, bracketed paste) están pendientes.
- Atlas limitado a 1024x1024 (si se llena, no aparecen nuevos caracteres hasta reconstruirlo).
- No hay todavía sistema de ligaduras, emojis a color, estilos de subrayado especiales ni shaping complejo.
- Ciertas secuencias ANSI pueden necesitar trabajo adicional de compatibilidad.
- La transparencia real del escritorio queda desactivada hasta resolver composición de título/contenido.
- El protocolo JSON de cuadrícula completa y polling de 120 ms son provisionales; hay que optimizar deltas y las colas PTY.
- No se ha medido todavía memoria, FPS ni uso de GPU en macOS.

## Pruebas iniciales
```
./scripts/build-native-macos.sh
open dist/Nia.app
```

En Nia:
```
printf '\033[31mROJO \033[32mVERDE \033[0mNORMAL\n'
printf '\033[38;2;100;190;255mCOLOR RGB\033[0m\n'
printf 'Unicode: á ñ 文 😎\n'
stty size
```

Luego: `vim` o `nano`, redimensionar, selección + Cmd+C/Cmd+V, Tab, cursores, reinicio y recuperación de sesión.
