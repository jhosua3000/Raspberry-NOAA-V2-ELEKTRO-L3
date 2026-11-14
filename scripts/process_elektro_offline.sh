#!/bin/bash

set -Eeuo pipefail
umask 002

# Procesamiento offline de una captura IQ CS16 de ELEKTRO-L3.
# Uso: process_elektro_offline.sh ARCHIVO.cs16

if [[ $# -ne 1 ]]; then
    echo "Uso: $0 ARCHIVO.cs16" >&2
    exit 2
fi

CS16_FILE="$1"

if [[ ! -f "$CS16_FILE" || ! -r "$CS16_FILE" ]]; then
    echo "[ERROR] El archivo CS16 no existe o no se puede leer: $CS16_FILE" >&2
    exit 1
fi

CS16_FILE="$(realpath "$CS16_FILE")"
CS16_NAME="$(basename "$CS16_FILE")"

# Obtener frecuencia de muestreo y frecuencia central del nombre del archivo.
if [[ ! "$CS16_NAME" =~ ([0-9]+)SPS_([0-9]+)Hz\.cs16$ ]]; then
    echo "[ERROR] El nombre CS16 no contiene los parámetros SPS y Hz esperados." >&2
    exit 1
fi

SAMPLE_RATE="${BASH_REMATCH[1]}"
FREQUENCY="${BASH_REMATCH[2]}"

if [[ ! -f "$HOME/.noaa-v2.conf" ]]; then
    echo "[ERROR] No existe $HOME/.noaa-v2.conf" >&2
    exit 1
fi

source "$HOME/.noaa-v2.conf"
source "$NOAA_HOME/scripts/common.sh"

if [[ ! -x "$SATDUMP" ]]; then
    echo "[ERROR] SatDump no está disponible en $SATDUMP" >&2
    exit 1
fi

if [[ ! -d "$IMAGE_OUTPUT" ]]; then
    echo "[ERROR] No existe el directorio de imágenes: $IMAGE_OUTPUT" >&2
    exit 1
fi

if [[ "$FREQUENCY" != "1691000000" ]]; then
    echo "[ERROR] Frecuencia central inesperada: ${FREQUENCY} Hz. Se esperaba 1691000000 Hz." >&2
    exit 1
fi

echo "[INFO] Procesamiento offline ELEKTRO-L3."
echo "[INFO] Archivo IQ: $CS16_FILE"
echo "[INFO] Muestreo: ${SAMPLE_RATE} SPS."
echo "[INFO] Frecuencia: ${FREQUENCY} Hz."

# Identificar el archivo de origen para permitir recuperar ejecuciones interrumpidas.
CS16_SIZE="$(stat -c '%s' "$CS16_FILE")"
CS16_MTIME="$(stat -c '%Y' "$CS16_FILE")"
SOURCE_ID="$(printf '%s\0%s\0%s' "$CS16_FILE" "$CS16_SIZE" "$CS16_MTIME" | sha256sum | awk '{print $1}')"

TEMP_OUTPUT="${IMAGE_OUTPUT}/.elektro-offline-${BASHPID}"
RECOVERY_MODE=0
OUTPUT_DIR=""

if [[ -e "$TEMP_OUTPUT" ]]; then
    echo "[ERROR] Ya existe el directorio temporal: $TEMP_OUTPUT" >&2
    exit 1
fi

mapfile -t MATCHING_MARKERS < <(
    find "$IMAGE_OUTPUT" -mindepth 2 -maxdepth 2 -type f \
        -name '.source_cs16' -exec grep -lFx -- "$SOURCE_ID" {} + 2>/dev/null
)

if (( ${#MATCHING_MARKERS[@]} > 1 )); then
    echo "[ERROR] Hay varias capturas asociadas al mismo archivo CS16. Se requiere revisión." >&2
    exit 1
elif (( ${#MATCHING_MARKERS[@]} == 1 )); then
    OUTPUT_DIR="$(dirname "${MATCHING_MARKERS[0]}")"
    RECOVERY_MODE=1
    echo "[INFO] Se han localizado productos de una ejecución anterior."
    echo "[INFO] Se recuperará: $OUTPUT_DIR"
else
    echo "[INFO] No hay una ejecución anterior identificada. Se iniciará SatDump."

    if "$SATDUMP" elektro_lrit baseband \
        "$CS16_FILE" "$TEMP_OUTPUT" \
        --samplerate "$SAMPLE_RATE" \
        --baseband_format cs16; then
        :
    else
        STATUS=$?
        echo "[ERROR] SatDump ha fallado con código $STATUS." >&2
        exit "$STATUS"
    fi

    if [[ ! -d "$TEMP_OUTPUT/IMAGES" ]]; then
        echo "[ERROR] SatDump no ha generado el directorio IMAGES." >&2
        exit 1
    fi
fi

if [[ "$RECOVERY_MODE" -eq 1 ]]; then
    if [[ ! -d "$OUTPUT_DIR/IMAGES" ]]; then
        echo "[ERROR] La captura recuperada no contiene IMAGES." >&2
        exit 1
    fi
    PRODUCT_ROOT="$OUTPUT_DIR/IMAGES"
else
    PRODUCT_ROOT="$TEMP_OUTPUT/IMAGES"
fi

# Todos los productos L3 deben compartir el mismo timestamp UTC.
mapfile -t PRODUCT_FILES < <(
    find "$PRODUCT_ROOT" -type f \
        -regextype posix-extended \
        -regex '.*/L3_[0-9]+_[0-9]{8}T[0-9]{6}Z\.[^/]+$' \
        -print | sort
)

if (( ${#PRODUCT_FILES[@]} == 0 )); then
    echo "[ERROR] No se han encontrado productos L3 con timestamp UTC verificable." >&2
    exit 1
fi

PRODUCT_STAMP=""

for PRODUCT_FILE in "${PRODUCT_FILES[@]}"; do
    PRODUCT_NAME="$(basename "$PRODUCT_FILE")"

    if [[ ! "$PRODUCT_NAME" =~ ^L3_[0-9]+_([0-9]{8})T([0-9]{6})Z\. ]]; then
        echo "[ERROR] No se puede interpretar la fecha del producto: $PRODUCT_NAME" >&2
        exit 1
    fi

    CURRENT_STAMP="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}"

    if [[ -n "$PRODUCT_STAMP" && "$CURRENT_STAMP" != "$PRODUCT_STAMP" ]]; then
        echo "[ERROR] Los productos L3 contienen timestamps diferentes: $PRODUCT_STAMP y $CURRENT_STAMP" >&2
        exit 1
    fi

    PRODUCT_STAMP="$CURRENT_STAMP"
done

PRODUCT_DATE="${PRODUCT_STAMP:0:8}"
PRODUCT_TIME="${PRODUCT_STAMP:9:6}"
PRODUCT_ISO="${PRODUCT_DATE:0:4}-${PRODUCT_DATE:4:2}-${PRODUCT_DATE:6:2} ${PRODUCT_TIME:0:2}:${PRODUCT_TIME:2:2}:${PRODUCT_TIME:4:2}"

if ! EPOCH_START="$(date -u -d "$PRODUCT_ISO" +%s)"; then
    echo "[ERROR] No se pudo convertir la fecha UTC del producto." >&2
    exit 1
fi

FILENAME_BASE="ELEKTRO-L3-${PRODUCT_DATE}-${PRODUCT_TIME}"
EXPECTED_OUTPUT_DIR="${IMAGE_OUTPUT}/${FILENAME_BASE}"

if [[ "$RECOVERY_MODE" -eq 1 ]]; then
    if [[ "$OUTPUT_DIR" != "$EXPECTED_OUTPUT_DIR" ]]; then
        echo "[ERROR] La carpeta recuperada no coincide con la fecha de sus productos L3." >&2
        exit 1
    fi
else
    OUTPUT_DIR="$EXPECTED_OUTPUT_DIR"

    if [[ -e "$OUTPUT_DIR" ]]; then
        echo "[ERROR] Ya existe la captura de destino sin una identificación coincidente: $OUTPUT_DIR" >&2
        echo "[ERROR] No se sobrescribirá ni se volverá a procesar automáticamente." >&2
        exit 1
    fi

    printf '%s\n' "$SOURCE_ID" > "$TEMP_OUTPUT/.source_cs16"

    if ! mv "$TEMP_OUTPUT" "$OUTPUT_DIR"; then
        echo "[ERROR] No se pudieron colocar los productos en su carpeta definitiva." >&2
        exit 1
    fi
fi

echo "[INFO] Fecha del producto UTC: $PRODUCT_ISO"
echo "[INFO] Carpeta definitiva: $OUTPUT_DIR"
if [[ "$RECOVERY_MODE" -eq 1 ]]; then
    echo "[INFO] Recuperación: SatDump no se ha vuelto a ejecutar."
fi

# En offline no se conoce la ganancia aplicada al SDR de origen.
FINALIZATION_MARKER="$OUTPUT_DIR/.finalization_complete"

if [[ -f "$FINALIZATION_MARKER" ]]; then
    if [[ "$(cat "$FINALIZATION_MARKER")" != "$SOURCE_ID" ]]; then
        echo "[ERROR] El marcador de finalización no corresponde al CS16 de origen." >&2
        exit 1
    fi
    echo "[INFO] Comprobando imágenes y miniaturas de la captura recuperada..."

    IMAGES_DIR="${OUTPUT_DIR}/IMAGES"
    THUMB_CAPTURE_DIR="${IMAGE_OUTPUT}/thumb/${FILENAME_BASE}"

    mapfile -d '' IMAGE_FILES < <(
        find "$IMAGES_DIR" -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' \
            -o -iname '*.png' -o -iname '*.tif' \
            -o -iname '*.tiff' -o -iname '*.webp' \) \
            -print0 | sort -z
    )

    RECOVERY_IMG_COUNT=0

    for IMAGE_FILE in "${IMAGE_FILES[@]}"; do
        if ! /usr/bin/identify "$IMAGE_FILE" >/dev/null 2>&1; then
            continue
        fi

        RELATIVE_IMAGE="${IMAGE_FILE#"$OUTPUT_DIR"/}"
        THUMB_FILE="${THUMB_CAPTURE_DIR}/${RELATIVE_IMAGE}"

        if [[ ! -s "$THUMB_FILE" ]] || \
           ! /usr/bin/identify "$THUMB_FILE" >/dev/null 2>&1; then
            echo "[ERROR] Falta una miniatura válida para: $IMAGE_FILE" >&2
            exit 1
        fi

        ((RECOVERY_IMG_COUNT += 1))
    done

    if (( RECOVERY_IMG_COUNT < 1 )); then
        echo "[ERROR] No se ha encontrado ninguna pareja válida de imagen y miniatura." >&2
        exit 1
    fi

    echo "[INFO] Recuperación validada: $RECOVERY_IMG_COUNT imágenes y sus miniaturas."
    echo "[INFO] No se regeneran miniaturas."
else
    IMAGE_OUTPUT="$IMAGE_OUTPUT" \
    DB_FILE="$DB_FILE" \
    IMAGE_PROC_DIR="$IMAGE_PROC_DIR" \
    bash "$NOAA_HOME/scripts/finalize_elektro_l3.sh" \
        "$OUTPUT_DIR" "$FILENAME_BASE" "$EPOCH_START" "NULL" "--register"

    MARKER_TMP="${FINALIZATION_MARKER}.tmp.$$"
    printf '%s\n' "$SOURCE_ID" > "$MARKER_TMP"
    mv "$MARKER_TMP" "$FINALIZATION_MARKER"
fi

echo "[SUCCESS] Procesamiento offline ELEKTRO-L3 finalizado."
