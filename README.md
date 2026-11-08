# Monitor de métricas en fila para Conky (Lua + Cairo)

Widget de escritorio minimalista para XFCE que muestra, en cuatro tarjetas con esquinas redondeadas colocadas una al lado de la otra, el estado de la **CPU**, la **GPU**, la **RAM** y la **NPU** de un portátil con AMD Ryzen AI.

- **CPU**: uso total en anillo, temperatura, frecuencia, carga media y uso de cada hilo en una rejilla de 4×4.
- **GPU** (Radeon integrada): uso en anillo, temperatura, potencia, VRAM y gráfica de uso reciente.
- **RAM**: uso en anillo, memoria usada y total, swap y gráfica de uso reciente.
- **NPU** (XDNA): potencia actual, temperatura, pico de potencia de la sesión y gráfica de potencia.

Cada tarjeta tiene su propio color de acento (azul claro, lavanda, verde menta y ámbar).

---

## Archivos

Los tres archivos van en la misma carpeta, `~/.config/conky/`:

| Archivo | Función |
|---|---|
| `monitor.conf` | Configuración de Conky. Crea una ventana transparente del tamaño de la fila y carga el script Lua. No dibuja nada por sí misma. |
| `monitor.lua` | Dibuja las tarjetas con Cairo y lee las métricas de CPU, GPU y RAM directamente de `/proc` y `/sys`. |
| `sensores.sh` | Lee la temperatura y la potencia de la NPU mediante `xrt-smi` y guarda la salida en caché unos segundos, porque `xrt-smi` es lento. `monitor.lua` lo llama solo para la NPU. |

Estructura final:

```
~/.config/conky/
├── monitor.conf
├── monitor.lua
└── sensores.sh
~/.config/autostart/
└── conky-monitor.desktop     ← arranque automático (ver más abajo)
```

---

## Herramientas que utiliza

| Herramienta | Para qué se usa |
|---|---|
| **Conky** (paquete `conky-all`) | Motor del widget: crea la ventana en el escritorio, ejecuta el script Lua una vez por segundo y aporta datos como el uso de CPU por hilo, la frecuencia y la carga. |
| **Lua** | Lenguaje del script de dibujo. Viene integrado en Conky; no hay que instalarlo aparte. |
| **Cairo** | Librería de dibujo vectorial integrada en `conky-all`. Permite las esquinas redondeadas, los anillos y las gráficas, que Conky no sabe dibujar con sus elementos básicos. |
| **`/proc` y `/sys`** | Interfaces del kernel de las que se leen las métricas: `/proc/meminfo` (RAM), `/proc/cpuinfo` (modelo e hilos), el driver `k10temp` (temperatura de la CPU) y el driver `amdgpu` (uso, temperatura, potencia y VRAM de la GPU). |
| **XRT de Xilinx / `xrt-smi`** | Herramienta de AMD/Xilinx para la NPU. Se usa `xrt-smi examine -r platform`, que solo informa de temperatura y potencia; por eso la tarjeta de la NPU no muestra porcentaje de uso. |
| **Fuentes Inter y JetBrains Mono** | Tipografías del diseño. Son opcionales: sin ellas el widget funciona con la fuente por defecto. |
| **Compositor de XFCE (xfwm4)** | Necesario para que el fondo de la ventana sea transparente y solo se vean las tarjetas. |

---

## Instalación

1. Instala Conky y las fuentes:

   ```bash
   sudo apt install conky-all fonts-inter fonts-jetbrains-mono
   ```

2. Copia los archivos a su carpeta y da permiso de ejecución al script de sensores:

   ```bash
   mkdir -p ~/.config/conky
   cp monitor.conf monitor.lua sensores.sh ~/.config/conky/
   chmod +x ~/.config/conky/sensores.sh
   ```

3. Pon la ruta **completa** del script Lua en `monitor.conf`. Algunas versiones de Conky no expanden `~` en `lua_load`, así que conviene usar la ruta absoluta (cambia `navas` por tu usuario):

   ```lua
   lua_load = '/home/navas/.config/conky/monitor.lua',
   ```

4. Comprueba que el compositor está activo en *Configuración → Ajustes del gestor de ventanas → Compositor*.

5. Lánzalo para probarlo:

   ```bash
   conky -c ~/.config/conky/monitor.conf &
   ```

---

## Arranque automático al iniciar sesión

Conky necesita el escritorio para dibujarse, así que se arranca al **iniciar la sesión gráfica**, no al encender el equipo.

### Opción A: desde la interfaz de XFCE

*Configuración → Sesión e inicio → Inicio automático de aplicaciones → Añadir*, con estos valores:

- **Nombre**: `Conky monitor`
- **Comando**: `sh -c "sleep 3 && conky -c /home/navas/.config/conky/monitor.conf"`
- **Disparador**: al iniciar sesión

### Opción B: creando el archivo a mano

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/conky-monitor.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Conky monitor
Exec=sh -c "sleep 3 && conky -c /home/navas/.config/conky/monitor.conf"
X-GNOME-Autostart-enabled=true
EOF
```

El `sleep 3` deja unos segundos para que arranquen el escritorio y el compositor. Si al iniciar sesión el widget aparece con fondo negro o no se ve, súbelo a 5 o más; si siempre sale bien, puedes probar a bajarlo.

### Entorno de XRT para la NPU

Lo que se lanza desde el inicio automático **no lee** `~/.zshrc` ni `~/.bashrc`. Para que `xrt-smi` esté disponible en la sesión gráfica, añade al final de `~/.profile`:

```sh
. /opt/xilinx/xrt/setup.sh > /dev/null
```

Los cambios en `~/.profile` se aplican al cerrar sesión y volver a entrar. Como respaldo, `sensores.sh` también busca `xrt-smi` en `/opt/xilinx/xrt/bin`.

---

## Personalización

**En `monitor.lua`** (sección *Ajustes*, al principio del archivo):

- `COLOR`: color de acento de cada tarjeta, en hexadecimal (`0x87d7ff`, etc.).
- `RADIO`: radio de las esquinas en píxeles; `0` para esquinas rectas.
- `RAM_ETIQUETA`: texto opcional arriba a la derecha de la tarjeta de RAM, por ejemplo `"LPDDR5X"`. El tipo de memoria no se puede leer sin permisos de administrador, por eso está vacío por defecto.
- `NPU_CADA`: segundos entre lecturas de la NPU (por defecto 5).
- `MUESTRAS`: número de puntos de cada gráfica.

**En `monitor.conf`**:

- `alignment`: posición en pantalla (`top_middle`, `bottom_middle`, `top_left`, `bottom_right`…).
- `gap_x` y `gap_y`: separación respecto a los bordes de la pantalla.

Tras cualquier cambio, reinicia Conky:

```bash
pkill conky; conky -c ~/.config/conky/monitor.conf &
```

---

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| `conky_main execution failed: attempt to call a nil value` repetido | Conky no ha cargado `monitor.lua`. Revisa que `lua_load` tiene la ruta absoluta y que el archivo existe. Para ver el error real de carga: `conky -c ~/.config/conky/monitor.conf 2>&1 \| grep -v llua_do_call \| head -20`. |
| Rectángulo negro detrás de las tarjetas | El compositor está desactivado, o Conky arrancó antes que él. Actívalo o aumenta el `sleep` del arranque automático. |
| La tarjeta de la NPU muestra `–` | `xrt-smi` no responde o su salida tiene otro formato. Prueba `~/.config/conky/sensores.sh npu_power` y `xrt-smi examine -r platform`. Si el script da "Permiso denegado": `chmod +x ~/.config/conky/sensores.sh`. |
| Temperaturas de CPU o GPU con `–` | No se encuentran los drivers `k10temp` o `amdgpu`. Compruébalo con `cat /sys/class/hwmon/hwmon*/name`. |
| Tipografía distinta a la del diseño | Faltan las fuentes: `sudo apt install fonts-inter fonts-jetbrains-mono`. |
| Aparecen dos paneles superpuestos | Hay otra entrada de Conky en el inicio automático (por ejemplo, una configuración anterior). Desactívala o bórrala. |
| El panel da un pequeño salto cada pocos segundos | Es la consulta a `xrt-smi`, que bloquea brevemente. Puedes espaciarla subiendo `NPU_CADA`. |

---

## Entorno de referencia

- Ubuntu 26 con XFCE en sesión X11 (Conky no dibuja ventanas de escritorio en la sesión experimental de Wayland de XFCE).
- Portátil Lenovo con AMD Ryzen AI 7, GPU Radeon integrada y NPU XDNA con XRT de Xilinx instalado en `/opt/xilinx/xrt`.
