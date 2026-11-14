#!/bin/bash

set -Eeuo pipefail
umask 002

# Finalización común de capturas ELEKTRO-L3:
# valida imágenes, genera miniaturas y registra la captura.

if [[ $# -lt 4 || $# -gt 5 ]]; then
    echo "Uso: $0 OUTPUT_DIR FILENAME_BASE EPOCH_START GAIN|NULL [--register|--prepare-only]" >&2
    exit 2
fi

OUTPUT_DIR="$1"
FILENAME_BASE="$2"
EPOCH_START="$3"
GAIN="$4"
MODE="${5:---register}"

if [[ "$MODE" != "--register" && "$MODE" != "--prepare-only" ]]; then
    echo "[ERROR] Modo no válido: $MODE" >&2
    exit 2
fi

if [[ ! "$FILENAME_BASE" =~ ^ELEKTRO-L3-[0-9]{8}-[0-9]{6}$ ]]; then
    echo "[ERROR] Identificador de captura no válido." >&2
    exit 2
fi

if [[ ! "$EPOCH_START" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Timestamp Unix no válido." >&2
    exit 2
fi

if [[ -z "${IMAGE_OUTPUT:-}" || -z "${DB_FILE:-}" || -z "${IMAGE_PROC_DIR:-}" ]]; then
    echo "[ERROR] Faltan variables de configuración." >&2
    exit 1
fi

if [[ "$OUTPUT_DIR" != "${IMAGE_OUTPUT}/${FILENAME_BASE}" ]]; then
    echo "[ERROR] La ruta de salida no corresponde al identificador." >&2
    exit 1
fi

if [[ ! -d "$OUTPUT_DIR/IMAGES" ]]; then
    echo "[ERROR] No existe el directorio IMAGES de SatDump." >&2
    exit 1
fi

if [[ ! -f "$DB_FILE" ]]; then
    echo "[ERROR] No existe la base de datos: $DB_FILE" >&2
    exit 1
fi

if [[ ! -x /usr/bin/identify ]]; then
    echo "[ERROR] ImageMagick identify no está disponible." >&2
    exit 1
fi

if [[ ! -f "${IMAGE_PROC_DIR}/thumbnail.sh" ]]; then
    echo "[ERROR] No se encuentra thumbnail.sh." >&2
    exit 1
fi

if [[ ! -f "${IMAGE_PROC_DIR}/elektro_annotate.sh" ]]; then
    echo "[ERROR] No se encuentra elektro_annotate.sh." >&2
    exit 1
fi

# En modo de preparación no se consulta ni modifica SQLite.
if [[ "$MODE" == "--register" ]]; then
    if ! php -r '
    $db = new SQLite3($argv[1]);
    $db->enableExceptions(true);
    $stmt = $db->prepare("SELECT id FROM decoded_passes WHERE file_path = :path LIMIT 1");
    $stmt->bindValue(":path", $argv[2], SQLITE3_TEXT);
    $result = $stmt->execute();
    $row = $result->fetchArray(SQLITE3_ASSOC);
    $db->close();
    if ($row) {
        fwrite(STDERR, "[ERROR] La captura ya está registrada (id " . $row["id"] . ").\n");
        exit(1);
    }
    ' "$DB_FILE" "$FILENAME_BASE"; then
        echo "[ERROR] No se pudo comprobar si la captura ya existe." >&2
        exit 1
    fi
fi
echo "[INFO] Validando productos de imagen ELEKTRO-L3..."

IMAGES_DIR="${OUTPUT_DIR}/IMAGES"
THUMB_CAPTURE_DIR="${IMAGE_OUTPUT}/thumb/${FILENAME_BASE}"

mapfile -d '' IMAGE_FILES < <(
    find "$IMAGES_DIR" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' \
        -o -iname '*.png' -o -iname '*.tif' \
        -o -iname '*.tiff' -o -iname '*.webp' \) \
        -print0 | sort -z
)

if [[ ${#IMAGE_FILES[@]} -eq 0 ]]; then
    echo "[ERROR] SatDump no ha generado imágenes compatibles." >&2
    exit 1
fi

IMG_COUNT=0

for IMAGE_FILE in "${IMAGE_FILES[@]}"; do
    if ! /usr/bin/identify "$IMAGE_FILE" >/dev/null 2>&1; then
        echo "[WARNING] Imagen no válida; se omite: $IMAGE_FILE"
        continue
    fi

    # Añadir la cabecera antes de crear la miniatura.
    if ! bash "${IMAGE_PROC_DIR}/elektro_annotate.sh" "$IMAGE_FILE" "$EPOCH_START"; then
        echo "[ERROR] Falló la anotación ELEKTRO-L3: $IMAGE_FILE" >&2
        exit 1
    fi

    if ! /usr/bin/identify "$IMAGE_FILE" >/dev/null 2>&1; then
        echo "[ERROR] La imagen anotada no es válida: $IMAGE_FILE" >&2
        exit 1
    fi

    RELATIVE_IMAGE="${IMAGE_FILE#"$OUTPUT_DIR"/}"
    THUMB_FILE="${THUMB_CAPTURE_DIR}/${RELATIVE_IMAGE}"

    mkdir -p "$(dirname "$THUMB_FILE")"

    if ! bash "${IMAGE_PROC_DIR}/thumbnail.sh" \
        300 "$IMAGE_FILE" "$THUMB_FILE"; then
        echo "[ERROR] Falló la miniatura: $THUMB_FILE" >&2
        exit 1
    fi

    if [[ ! -s "$THUMB_FILE" ]] || \
       ! /usr/bin/identify "$THUMB_FILE" >/dev/null 2>&1; then
        echo "[ERROR] Miniatura inexistente o no válida: $THUMB_FILE" >&2
        exit 1
    fi

    ((IMG_COUNT += 1))
done

if (( IMG_COUNT < 1 )); then
    echo "[ERROR] No se ha podido validar ninguna imagen." >&2
    exit 1
fi

echo "[INFO] Imágenes validadas y miniaturas creadas: $IMG_COUNT"

if [[ "$MODE" == "--register" ]]; then
    # Registrar únicamente después de validar todos los productos.
    # La transacción impide duplicados incluso si dos procesos coinciden.
    if ! php -r '
    $db = new SQLite3($argv[1]);
    $db->enableExceptions(true);

    try {
        $db->exec("BEGIN IMMEDIATE");

        $check = $db->prepare(
            "SELECT id FROM decoded_passes WHERE file_path = :file_path LIMIT 1"
        );
        $check->bindValue(":file_path", $argv[2], SQLITE3_TEXT);
        $result = $check->execute();

        if ($result->fetchArray(SQLITE3_ASSOC)) {
            throw new RuntimeException("La captura ya está registrada.");
        }

        $stmt = $db->prepare(
            "INSERT INTO decoded_passes
             (pass_start, file_path, daylight_pass, sat_type, img_count, gain, capture_time)
             VALUES (NULL, :file_path, 0, 2, :img_count, :gain, :capture_time)"
        );

        $stmt->bindValue(":file_path", $argv[2], SQLITE3_TEXT);
        $stmt->bindValue(":img_count", (int)$argv[3], SQLITE3_INTEGER);

        if ($argv[4] === "NULL") {
            $stmt->bindValue(":gain", null, SQLITE3_NULL);
        } else {
            $stmt->bindValue(":gain", (float)$argv[4], SQLITE3_FLOAT);
        }

        $stmt->bindValue(":capture_time", (int)$argv[5], SQLITE3_INTEGER);
        $stmt->execute();

        $db->exec("COMMIT");
        $db->close();
    } catch (Throwable $e) {
        try {
            $db->exec("ROLLBACK");
        } catch (Throwable $ignored) {
        }
        $db->close();
        fwrite(STDERR, "[ERROR] " . $e->getMessage() . "\n");
        exit(1);
    }
    ' "$DB_FILE" "$FILENAME_BASE" "$IMG_COUNT" "$GAIN" "$EPOCH_START"; then
        echo "[ERROR] No se pudo registrar la captura ELEKTRO-L3." >&2
        exit 1
    fi
    echo "[SUCCESS] ELEKTRO-L3: captura validada y registrada. Imágenes: $IMG_COUNT"
else
    echo "[SUCCESS] ELEKTRO-L3: preparación validada; miniaturas creadas: $IMG_COUNT. SQLite no se ha modificado."
fi
exit 0
