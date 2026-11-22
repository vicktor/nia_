# Ember Terminal 0.1.5 (prototipo)

- Cursor visible en posición VT100; opciones bloque, barra y subrayado, con parpadeo configurable.
- ⌘1...⌘9 abre las nueve primeras sesiones guardadas (incluyendo archivadas).
- ⌘B oculta/muestra barra lateral. Botón siempre disponible en barra superior.
- Panel lateral reorganizado; ajustes plegables y controles más compactos.
- Preferencias de cursor y panel guardadas en la tabla existente `preferences` de SQLite.

**Limitaciones:** no probado en macOS en este entorno; renderizado de glifos sigue siendo egui, y el bucle de repaint sigue a 30 Hz. Los comandos con ⌘ funcionan cuando Ember está activo; macOS puede interceptar algunos atajos. El orden ⌘1–9 corresponde a la lista mostrada.
