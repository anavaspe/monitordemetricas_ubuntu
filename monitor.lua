-- Monitor minimalista en fila para conky: CPU · GPU · RAM · NPU
-- Se carga desde monitor.conf. Lee los sensores directamente de /sys y /proc;
-- la NPU se consulta con ~/.config/conky/sensores.sh (que usa xrt-smi).

require 'cairo'
pcall(require, 'cairo_xlib')   -- necesario en conky 1.19 o posterior

-- ================= Ajustes =================
local COLOR = { cpu = 0x87d7ff, gpu = 0xc4a7ff, ram = 0x7ee2b8, npu = 0xffd27a }
local RADIO = 18                  -- radio de las esquinas (0 = esquinas rectas)
local RAM_ETIQUETA = ""           -- texto arriba a la derecha de la RAM, p. ej. "LPDDR5X"
local FUENTE = "Inter"
local FUENTE_MONO = "JetBrains Mono"
local SENSORES = os.getenv("HOME") .. "/.config/conky/sensores.sh"
local NPU_CADA = 5                -- segundos entre lecturas de la NPU
local MUESTRAS = 40               -- puntos de cada gráfica

local TXT, TXT_FUERTE, TXT_SUAVE, TXT_ETIQ = 0xe6edf3, 0xf1f5f9, 0x8a96a2, 0x9aa6b2
local FONDO, FONDO_ALFA, BORDE_ALFA = 0x161b22, 0.78, 0.07
local PAD, GAP = 18, 14
local ANCHO_CPU, ANCHO = 330, 250

-- ================= Utilidades =================
local function leer(ruta)
  local f = io.open(ruta, "r")
  if not f then return nil end
  local s = f:read("*l")
  f:close()
  return s
end

local function num(s) return tonumber(s or "") end

local function sensor(ruta, divisor)
  local v = ruta and num(leer(ruta))
  return v and v / divisor
end

local function coma(v, dec)
  return (string.format("%." .. dec .. "f", v):gsub("%.", ","))
end

local function fmt(v, dec, unidad)
  if not v then return "–" end
  return coma(v, dec) .. unidad
end

local function redondo(v) return math.floor((v or 0) + 0.5) end

-- ================= Detección de sensores (una sola vez) =================
local rutas

local function buscar_rutas()
  local r = { hilos = 0 }
  local p = io.popen("ls -d /sys/class/hwmon/hwmon* 2>/dev/null")
  if p then
    for h in p:lines() do
      local nombre = leer(h .. "/name")
      if nombre == "k10temp" then
        r.cpu_temp = h .. "/temp1_input"
      elseif nombre == "amdgpu" then
        r.gpu_temp = h .. "/temp1_input"
        r.gpu_pot = leer(h .. "/power1_average") and (h .. "/power1_average") or (h .. "/power1_input")
      end
    end
    p:close()
  end
  for i = 0, 9 do
    local d = "/sys/class/drm/card" .. i .. "/device"
    if leer(d .. "/gpu_busy_percent") then r.gpu = d break end
  end
  local f = io.open("/proc/cpuinfo", "r")
  if f then
    for l in f:lines() do
      if l:match("^processor") then r.hilos = r.hilos + 1 end
      if not r.modelo then r.modelo = l:match("^model name%s*:.-(Ryzen AI %d+)") end
    end
    f:close()
  end
  r.modelo = r.modelo or "CPU"
  return r
end

local function memoria()
  local f = io.open("/proc/meminfo", "r")
  if not f then return nil end
  local m = {}
  for l in f:lines() do
    local k, v = l:match("^(%w+):%s+(%d+)")
    if k then m[k] = tonumber(v) end
  end
  f:close()
  local total = m.MemTotal or 1
  local usada = total - (m.MemAvailable or 0)
  return {
    pct = usada / total * 100,
    usada = usada / 1048576,
    total = total / 1048576,
    swap = ((m.SwapTotal or 0) - (m.SwapFree or 0)) / 1048576,
  }
end

-- NPU: xrt-smi es lento, así que solo se consulta cada NPU_CADA segundos
local npu = { temp = nil, pot = nil, pico = 0, t = -1e9 }

local function leer_npu()
  local ahora = os.time()
  if ahora - npu.t < NPU_CADA then return end
  npu.t = ahora
  local function pedir(arg)
    local p = io.popen(SENSORES .. " " .. arg .. " 2>/dev/null")
    if not p then return nil end
    local s = p:read("*l")
    p:close()
    return num(s)
  end
  npu.temp = pedir("npu_temp")
  npu.pot = pedir("npu_power")
  if npu.pot and npu.pot > npu.pico then npu.pico = npu.pot end
end

local historial = { gpu = {}, ram = {}, npu = {} }

local function apuntar(t, v)
  t[#t + 1] = v or 0
  if #t > MUESTRAS then table.remove(t, 1) end
end

-- ================= Dibujo =================
local function rgba(cr, c, a)
  cairo_set_source_rgba(cr,
    math.floor(c / 65536) % 256 / 255,
    math.floor(c / 256) % 256 / 255,
    c % 256 / 255,
    a or 1)
end

local function rect_redondeado(cr, x, y, w, h, r)
  r = math.min(r, w / 2, h / 2)
  cairo_new_sub_path(cr)
  cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
  cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
  cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
  cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
  cairo_close_path(cr)
end

local function fuente(cr, tam, mono, negrita)
  cairo_select_font_face(cr, mono and FUENTE_MONO or FUENTE, CAIRO_FONT_SLANT_NORMAL,
    negrita and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
  cairo_set_font_size(cr, tam)
end

local function ancho_texto(cr, s)
  local e = cairo_text_extents_t:create()
  tolua.takeownership(e)
  cairo_text_extents(cr, s, e)
  return e.x_advance
end

-- opciones: mono, negrita, derecha, centro
local function texto(cr, s, x, y, tam, color, o)
  o = o or {}
  fuente(cr, tam, o.mono, o.negrita)
  local w = ancho_texto(cr, s)
  if o.derecha then x = x - w elseif o.centro then x = x - w / 2 end
  rgba(cr, color)
  cairo_move_to(cr, x, y)
  cairo_show_text(cr, s)
  cairo_new_path(cr)
  return w
end

-- Título con espaciado entre letras, como en el diseño
local function etiqueta(cr, s, x, y, color)
  for letra in s:gmatch(".") do
    x = x + texto(cr, letra, x, y, 11, color, { negrita = true }) + 1.3
  end
end

local function tarjeta(cr, x, y, w, h)
  rect_redondeado(cr, x + 0.5, y + 0.5, w - 1, h - 1, RADIO)
  rgba(cr, FONDO, FONDO_ALFA)
  cairo_fill_preserve(cr)
  rgba(cr, 0xffffff, BORDE_ALFA)
  cairo_set_line_width(cr, 1)
  cairo_stroke(cr)
end

local function anillo(cr, cx, cy, pct, color)
  pct = math.max(0, math.min(pct or 0, 100))
  cairo_set_line_width(cr, 6)
  cairo_new_path(cr)
  rgba(cr, 0xffffff, 0.08)
  cairo_arc(cr, cx, cy, 32, 0, 2 * math.pi)
  cairo_stroke(cr)
  if pct > 0 then
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
    rgba(cr, color)
    cairo_arc(cr, cx, cy, 32, -math.pi / 2, -math.pi / 2 + 2 * math.pi * pct / 100)
    cairo_stroke(cr)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
  end
  -- cifra centrada: número grande + "%" pequeño
  local cifra = tostring(redondo(pct))
  fuente(cr, 18, false, true)
  local w1 = ancho_texto(cr, cifra)
  fuente(cr, 11, false, false)
  local w2 = ancho_texto(cr, "%")
  local x = cx - (w1 + 1 + w2) / 2
  texto(cr, cifra, x, cy + 6, 18, TXT_FUERTE, { negrita = true })
  texto(cr, "%", x + w1 + 1, cy + 6, 11, TXT_ETIQ)
end

local function fila(cr, x1, x2, y, nombre, valor)
  texto(cr, nombre, x1, y, 12, TXT_SUAVE)
  texto(cr, valor, x2, y, 12, TXT, { mono = true, derecha = true })
end

local function grafica(cr, t, x, y, w, h, maximo, color)
  if #t < 2 then return end
  local paso = w / (MUESTRAS - 1)
  local x0 = x + w - (#t - 1) * paso
  cairo_new_path(cr)
  for i, v in ipairs(t) do
    local py = y + h - 1 - math.min(v / maximo, 1) * (h - 2)
    if i == 1 then cairo_move_to(cr, x0, py) else cairo_line_to(cr, x0 + (i - 1) * paso, py) end
  end
  cairo_set_line_width(cr, 1.6)
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
  rgba(cr, color)
  cairo_stroke(cr)
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
end

-- ================= Bucle principal =================
function conky_main()
  if conky_window == nil then return end
  if (num(conky_parse("${updates}")) or 0) < 3 then return end
  if not rutas then rutas = buscar_rutas() end

  -- Lecturas
  local cpu_total = num(conky_parse("${cpu cpu0}")) or 0
  local nucleos = {}
  for i = 1, math.min(rutas.hilos, 16) do
    nucleos[i] = num(conky_parse("${cpu cpu" .. i .. "}")) or 0
  end
  local frec = num(conky_parse("${freq_g}"))
  local carga = num(conky_parse("${loadavg 1}"))
  local cpu_temp = sensor(rutas.cpu_temp, 1000)

  local gpu_uso = rutas.gpu and num(leer(rutas.gpu .. "/gpu_busy_percent")) or 0
  local gpu_temp = sensor(rutas.gpu_temp, 1000)
  local gpu_pot = sensor(rutas.gpu_pot, 1e6)
  local vram_u = rutas.gpu and sensor(rutas.gpu .. "/mem_info_vram_used", 2 ^ 30)
  local vram_t = rutas.gpu and sensor(rutas.gpu .. "/mem_info_vram_total", 2 ^ 30)

  local mem = memoria() or { pct = 0, usada = 0, total = 0, swap = 0 }
  leer_npu()

  apuntar(historial.gpu, gpu_uso)
  apuntar(historial.ram, mem.pct)
  apuntar(historial.npu, npu.pot)

  -- Superficie de dibujo
  local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
    conky_window.visual, conky_window.width, conky_window.height)
  local cr = cairo_create(cs)

  local filas = math.max(1, math.ceil(#nucleos / 4))
  local y = 1
  local H = PAD + 11 + 14 + 76 + 14 + filas * 22 + (filas - 1) * 10 + PAD
  local cy = y + PAD + 11 + 14 + 38          -- centro vertical de anillos y datos
  local yt = y + PAD + 9                     -- línea base de los títulos
  local x = 1

  -- CPU
  tarjeta(cr, x, y, ANCHO_CPU, H)
  etiqueta(cr, "CPU", x + PAD, yt, COLOR.cpu)
  texto(cr, rutas.modelo .. " · " .. rutas.hilos .. " hilos", x + ANCHO_CPU - PAD, yt, 11, TXT_SUAVE, { derecha = true })
  anillo(cr, x + PAD + 38, cy, cpu_total, COLOR.cpu)
  local x1, x2 = x + PAD + 76 + 16, x + ANCHO_CPU - PAD
  fila(cr, x1, x2, cy - 18, "Temp", fmt(cpu_temp, 0, " °C"))
  fila(cr, x1, x2, cy + 4, "Frec", fmt(frec, 1, " GHz"))
  fila(cr, x1, x2, cy + 26, "Carga", fmt(carga, 2, ""))

  local gy = y + PAD + 11 + 14 + 76 + 14
  local colw = (ANCHO_CPU - 2 * PAD - 30) / 4
  for i, p in ipairs(nucleos) do
    local cx0 = x + PAD + ((i - 1) % 4) * (colw + 10)
    local ry = gy + math.floor((i - 1) / 4) * 32
    texto(cr, "C" .. i, cx0, ry + 9, 10, TXT_SUAVE)
    texto(cr, redondo(p) .. "%", cx0 + colw, ry + 10, 11, TXT, { mono = true, derecha = true })
    rect_redondeado(cr, cx0, ry + 18, colw, 4, 2)
    rgba(cr, 0xffffff, 0.08)
    cairo_fill(cr)
    if p > 0 then
      rect_redondeado(cr, cx0, ry + 18, math.max(colw * math.min(p, 100) / 100, 4), 4, 2)
      rgba(cr, COLOR.cpu)
      cairo_fill(cr)
    end
  end
  x = x + ANCHO_CPU + GAP

  -- GPU
  tarjeta(cr, x, y, ANCHO, H)
  etiqueta(cr, "GPU", x + PAD, yt, COLOR.gpu)
  texto(cr, "Radeon", x + ANCHO - PAD, yt, 11, TXT_SUAVE, { derecha = true })
  anillo(cr, x + PAD + 38, cy, gpu_uso, COLOR.gpu)
  x1, x2 = x + PAD + 76 + 16, x + ANCHO - PAD
  fila(cr, x1, x2, cy - 18, "Temp", fmt(gpu_temp, 0, " °C"))
  fila(cr, x1, x2, cy + 4, "Pot.", fmt(gpu_pot, 1, " W"))
  fila(cr, x1, x2, cy + 26, "VRAM",
    (vram_u and vram_t) and (coma(vram_u, 1) .. "/" .. coma(vram_t, 0) .. " GB") or "–")
  grafica(cr, historial.gpu, x + PAD, y + H - PAD - 30, ANCHO - 2 * PAD, 30, 100, COLOR.gpu)
  x = x + ANCHO + GAP

  -- RAM
  tarjeta(cr, x, y, ANCHO, H)
  etiqueta(cr, "RAM", x + PAD, yt, COLOR.ram)
  if RAM_ETIQUETA ~= "" then
    texto(cr, RAM_ETIQUETA, x + ANCHO - PAD, yt, 11, TXT_SUAVE, { derecha = true })
  end
  anillo(cr, x + PAD + 38, cy, mem.pct, COLOR.ram)
  x1, x2 = x + PAD + 76 + 16, x + ANCHO - PAD
  fila(cr, x1, x2, cy - 18, "Usada", coma(mem.usada, 1) .. " GB")
  fila(cr, x1, x2, cy + 4, "Total", coma(mem.total, 0) .. " GB")
  fila(cr, x1, x2, cy + 26, "Swap", coma(mem.swap, 1) .. " GB")
  grafica(cr, historial.ram, x + PAD, y + H - PAD - 30, ANCHO - 2 * PAD, 30, 100, COLOR.ram)
  x = x + ANCHO + GAP

  -- NPU
  tarjeta(cr, x, y, ANCHO, H)
  etiqueta(cr, "NPU", x + PAD, yt, COLOR.npu)
  texto(cr, "XDNA", x + ANCHO - PAD, yt, 11, TXT_SUAVE, { derecha = true })
  local w = texto(cr, fmt(npu.pot, 1, ""), x + PAD, cy + 4, 30, TXT_FUERTE, { negrita = true })
  texto(cr, "W", x + PAD + w + 3, cy + 4, 13, TXT_ETIQ)
  texto(cr, "potencia", x + PAD, cy + 22, 11, TXT_SUAVE)
  x1, x2 = x + PAD + 76 + 16, x + ANCHO - PAD
  fila(cr, x1, x2, cy - 7, "Temp", fmt(npu.temp, 0, " °C"))
  fila(cr, x1, x2, cy + 15, "Pico", npu.pico > 0 and (coma(npu.pico, 1) .. " W") or "–")
  grafica(cr, historial.npu, x + PAD, y + H - PAD - 30, ANCHO - 2 * PAD, 30,
    math.max(npu.pico, 1), COLOR.npu)

  cairo_destroy(cr)
  cairo_surface_destroy(cs)
end
