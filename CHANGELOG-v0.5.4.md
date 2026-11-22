# Nia v0.5.4

- Las contraseñas generadas tienen exactamente 18 caracteres.
- Alfabeto: A-Z, a-z, 0-9 y `/()=?¿.:,-_%$#·`.
- Se garantiza al menos un carácter de cada grupo (mayúscula, minúscula, cifra y símbolo).
- SecRandomCopyBytes y muestreo sin sesgo para generar y mezclar caracteres.
- Inserción entre comillas simples como argumento seguro de Zsh/Bash.
- No se ejecuta Enter automáticamente.

Nota: para introducirla en un prompt que solicite una contraseña literalmente,
las comillas de shell no deben incluirse: la función de inserción está pensada
para preparar argumentos de comandos.
