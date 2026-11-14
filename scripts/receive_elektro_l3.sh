#!/bin/bash

set -Eeuo pipefail
umask 002

# Receptor independiente ELEKTRO-L3 LRIT.
# Argumentos:
#   1. Epoch de inicio previsto (UTC)
#   2. Duración de la captura en segundos

if [[ $# -ne 2 ]]; then
    echo "Uso: $0 EPOCH_INICIO DURACION_SEGUNDOS" >&2
    exit 2
fi

EPOCH_START="$1"
CAPTURE_TIME="$2"

if [[ ! "$EPOCH_START" =~ ^[0-9]+$ || ! "$CAPTURE_TIME" =~ ^[0-9]+$ ]] ||
   (( CAPTURE_TIME < 1 )); then
    echo "ERROR: epoch o duración no válidos." >&2
    exit 2
fi

if [[ ! -f "$HOME/.noaa-v2.conf" ]]; then
    echo "ERROR: no existe $HOME/.noaa-v2.conf" >&2
    exit 1
fi

source "$HOME/.noaa-v2.conf"
source "$NOAA_HOME/scripts/common.sh"

SAT_NAME="ELEKTRO-L3"
FILENAME_BASE="ELEKTRO-L3-$(date -u -d "@${EPOCH_START}" +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${IMAGE_OUTPUT}/${FILENAME_BASE}"

SDR_DEVICE_ID="${ELEKTRO_L3_SDR_DEVICE_ID:?Falta ELEKTRO_L3_SDR_DEVICE_ID}"
GAIN="${ELEKTRO_L3_GAIN:?Falta ELEKTRO_L3_GAIN}"

if [[ "${ELEKTRO_L3_FREQ_OFFSET:-0}" != "0" ]]; then
    log "ELEKTRO-L3: frecuencia desplazada configurada, pero aún no está implementada en el receptor." "ERROR"
    exit 1
fi

if [[ ! -x "$SATDUMP" ]]; then
    log "ELEKTRO-L3: no se encuentra SatDump ejecutable en $SATDUMP." "ERROR"
    exit 1
fi

if [[ ! -d "$IMAGE_OUTPUT" ]]; then
    log "ELEKTRO-L3: no existe el directorio de salida $IMAGE_OUTPUT." "ERROR"
    exit 1
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    log "ELEKTRO-L3: ya existe el directorio de esta captura: $OUTPUT_DIR" "ERROR"
    exit 1
fi


mkdir -p "$OUTPUT_DIR"

log "ELEKTRO-L3: comienza captura LRIT." "INFO"
log "Inicio previsto UTC: $(date -u -d "@${EPOCH_START}" '+%Y-%m-%d %H:%M:%S')" "INFO"
log "Duración: ${CAPTURE_TIME} segundos." "INFO"
log "SDR: ${SDR_DEVICE_ID}; ganancia: ${GAIN} dB." "INFO"
log "Directorio de salida: ${OUTPUT_DIR}" "INFO"

SDR_OPTIONS=(--source rtlsdr --samplerate 1e6 --frequency 1691e6)

if [[ "${USE_DEVICE_STRING:-false}" == "true" ]]; then
    SDR_OPTIONS+=(--source_id "$SDR_DEVICE_ID")
fi

SDR_OPTIONS+=(--gain "$GAIN")

if [[ "${ELEKTRO_L3_ENABLE_BIAS_TEE:-}" == "-T" ]]; then
    SDR_OPTIONS+=(--bias)
fi

set +e
"$SATDUMP" live elektro_lrit "$OUTPUT_DIR" \
    "${SDR_OPTIONS[@]}" \
    --timeout "$CAPTURE_TIME" >> "$NOAA_LOG" 2>&1
SATDUMP_STATUS=$?
set -e

if (( SATDUMP_STATUS != 0 )); then
    log "ELEKTRO-L3: SatDump terminó con código ${SATDUMP_STATUS}." "ERROR"
    exit "$SATDUMP_STATUS"
fi

log "ELEKTRO-L3: SatDump terminó. Productos pendientes de validación." "INFO"
log "Salida conservada en: ${OUTPUT_DIR}" "INFO"


# ELEKTRO_IMAGE_VALIDATION_BEGIN
IMAGE_OUTPUT="$IMAGE_OUTPUT" \
DB_FILE="$DB_FILE" \
IMAGE_PROC_DIR="$IMAGE_PROC_DIR" \
bash "${NOAA_HOME}/scripts/finalize_elektro_l3.sh" \
    "$OUTPUT_DIR" "$FILENAME_BASE" "$EPOCH_START" "$GAIN"
# ELEKTRO_IMAGE_VALIDATION_END

exit 0
