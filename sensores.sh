#!/usr/bin/env bash
# Lecturas de sensores para conky: CPU (k10temp), GPU (amdgpu) y NPU (xrt-smi)
# Uso: sensores.sh {cpu_temp|gpu_busy|gpu_temp|gpu_power|gpu_vram|npu_temp|npu_power}

# Busca el directorio hwmon de un driver concreto (k10temp, amdgpu...)
find_hwmon() {
  for h in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$h/name" 2>/dev/null)" == "$1" ]] && { echo "$h"; return; }
  done
}

# Busca la tarjeta gráfica que usa el driver amdgpu (puede ser card0 o card1)
gpu_dev() {
  for c in /sys/class/drm/card[0-9]; do
    [[ "$(basename "$(readlink -f "$c/device/driver")")" == amdgpu ]] && { echo "$c/device"; return; }
  done
}

# xrt-smi tarda en responder, así que su salida se guarda en caché unos segundos
NPU_CACHE="/tmp/conky_npu_${USER}.txt"
npu_refresh() {
  local edad=999
  [[ -f "$NPU_CACHE" ]] && edad=$(( $(date +%s) - $(stat -c %Y "$NPU_CACHE") ))
  if (( edad >= 4 )); then
    local xrt tmp
    xrt=$(command -v xrt-smi || echo /opt/xilinx/xrt/bin/xrt-smi)
    tmp=$(mktemp)
    "$xrt" examine -r platform > "$tmp" 2>/dev/null && mv "$tmp" "$NPU_CACHE" || rm -f "$tmp"
  fi
}

# Extrae el primer número de una línea
num() { grep -oE '[0-9]+([.][0-9]+)?' | head -1; }

case "$1" in
  cpu_temp)
    h=$(find_hwmon k10temp)
    val=$(awk '{printf "%.0f", $1/1000}' "$h/temp1_input" 2>/dev/null) ;;
  gpu_busy)
    val=$(cat "$(gpu_dev)/gpu_busy_percent" 2>/dev/null) ;;
  gpu_temp)
    h=$(find_hwmon amdgpu)
    val=$(awk '{printf "%.0f", $1/1000}' "$h/temp1_input" 2>/dev/null) ;;
  gpu_power)
    h=$(find_hwmon amdgpu)
    f="$h/power1_average"; [[ -r "$f" ]] || f="$h/power1_input"
    val=$(awk '{printf "%.1f", $1/1000000}' "$f" 2>/dev/null) ;;
  gpu_vram)
    d=$(gpu_dev)
    val=$(awk -v u="$(cat "$d/mem_info_vram_used" 2>/dev/null)" \
              -v t="$(cat "$d/mem_info_vram_total" 2>/dev/null)" \
              'BEGIN{ if (t>0) printf "%d / %d MiB", u/1048576, t/1048576 }') ;;
  npu_temp)
    npu_refresh
    val=$(grep -iE 'temp' "$NPU_CACHE" 2>/dev/null | num) ;;
  npu_power)
    npu_refresh
    val=$(grep -iE 'power.*(W|watt)' "$NPU_CACHE" 2>/dev/null | num) ;;
esac

echo "${val:--}"
