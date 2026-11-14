#!/bin/bash
set -Eeuo pipefail

NOAA_HOME="/home/pi/raspberry-noaa-v2"
CS16_FILE="/srv/images/ELEKTRO-L3-20261110-201000/IMAGES/2026-11-07_15-41-13_512000SPS_1691000000Hz.cs16"

# Cargar configuración y herramientas del proyecto
source "$HOME/.noaa-v2.conf"
source "$NOAA_HOME/scripts/common.sh"

# Comprobar archivo original
if [[ ! -f "$CS16_FILE" ]]; then
    echo "ERROR: No existe el archivo CS16:"
    echo "$CS16_FILE"
    exit 1
fi

# Obtener parámetros del nombre del archivo
if [[ "$CS16_FILE" =~ _([0-9]+)SPS_([0-9]+)Hz\.cs16$ ]]; then
    SAMPLE_RATE="${BASH_REMATCH[1]}"
    FREQUENCY="${BASH_REMATCH[2]}"
else
    echo "ERROR: No se pudieron extraer los parámetros del archivo."
    exit 1
fi

# Comprobar SatDump
if [[ -z "${SATDUMP:-}" || ! -x "$SATDUMP" ]]; then
    echo "ERROR: SatDump no está disponible."
    exit 1
fi

# Directorio temporal exclusivo para el diagnóstico
TEMP_OUTPUT="$(mktemp -d "${IMAGE_OUTPUT%/}/.elektro-diagnostico-XXXXXX")"

echo "=========================================="
echo " DIAGNÓSTICO OFFLINE ELEKTRO-L3"
echo "=========================================="
echo "Archivo:       $CS16_FILE"
echo "Muestreo:      $SAMPLE_RATE SPS"
echo "Frecuencia:    $FREQUENCY Hz"
echo "SatDump:       $SATDUMP"
echo "Salida:        $TEMP_OUTPUT"
echo "=========================================="

# Procesamiento SatDump. No se ejecuta el finalizador.
"$SATDUMP" elektro_lrit baseband \
    "$CS16_FILE" \
    "$TEMP_OUTPUT" \
    --samplerate "$SAMPLE_RATE" \
    --baseband_format cs16

echo
echo "=========================================="
echo " PROCESAMIENTO TERMINADO"
echo "=========================================="
echo "Resultados conservados en:"
echo "$TEMP_OUTPUT"
echo
echo "No se han registrado capturas en SQLite."
echo "No se han publicado imágenes en el panel."
echo "No se han generado miniaturas."
