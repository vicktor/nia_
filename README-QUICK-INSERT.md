# Quick Insert

En Nia haz clic derecho dentro del terminal. Puedes insertar UUID v4, SHA-1/MD5 de valores generados de forma aleatoria o una contraseña de 28 caracteres. La inserción es texto en la PTY y **no ejecuta el comando**. SHA-1 y MD5 se mantienen como generadores de identificadores heredados, nunca para hashing de contraseñas, firmas o usos criptográficos de seguridad. UUID v4 es la opción recomendada para identificadores.

**Doble Escape** limpia una línea de comandos en Zsh/Bash con bindings tipo Emacs, usando Ctrl+A y Ctrl+K. En shells con modo vi o programas interactivos, esa secuencia puede tener otro significado. Escape simple se entrega tras una demora de 320 ms.

## Pruebas

1. En dos paneles escribe `echo `, clic derecho en el segundo, UUID: debe entrar en segundo panel, sin pulsar Enter.
2. Genera SHA-1, MD5, password y comprueba sus longitudes 40, 32, 28 y caracteres válidos.
3. Escribe `echo prueba`, pulsa Escape dos veces seguidas: la línea debería vaciarse con el modo Emacs habitual.
4. Pulsa Escape una sola vez en `vim` y comprueba que sigue funcionando (con un pequeño retraso).
