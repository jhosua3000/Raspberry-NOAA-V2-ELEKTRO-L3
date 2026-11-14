#!/bin/bash
set -Eeuo pipefail

IMAGE_FILE="${1:?Falta la ruta de la imagen}"
FALLBACK_EPOCH="${2:-}"

NOAA_HOME="${NOAA_HOME:-$HOME/raspberry-noaa-v2}"
LOGO="$NOAA_HOME/config/annotation/11.png"
HEADER_HEIGHT=330
MARKER="RNOAA_ELEKTRO_HEADER_V1"

[[ -f "$IMAGE_FILE" ]] || { echo "ERROR: no existe $IMAGE_FILE" >&2; exit 1; }
[[ "${IMAGE_FILE,,}" == *.png ]] || { echo "AVISO: formato no PNG, se omite: $IMAGE_FILE"; exit 0; }
[[ -f "$LOGO" ]] || { echo "ERROR: no se encuentra el logotipo $LOGO" >&2; exit 1; }

IDENTIFY="${IDENTIFY:-$(command -v identify)}"
CONVERT="${CONVERT:-$(command -v convert)}"
WKHTMLTOIMG="${WKHTMLTOIMG:-$(command -v wkhtmltoimage)}"

[[ -x "$IDENTIFY" && -x "$CONVERT" && -x "$WKHTMLTOIMG" ]] || {
  echo "ERROR: falta identify, convert o wkhtmltoimage" >&2
  exit 1
}

if "$IDENTIFY" -format '%c' "$IMAGE_FILE" 2>/dev/null | grep -q "$MARKER"; then
  echo "Cabecera ELEKTRO ya presente: $IMAGE_FILE"
  exit 0
fi

WIDTH=$("$IDENTIFY" -format '%w' "$IMAGE_FILE")
[[ "$WIDTH" =~ ^[0-9]+$ ]] || { echo "ERROR: no se pudo obtener el ancho" >&2; exit 1; }

BASE="$(basename "$IMAGE_FILE")"
PRODUCT="PRODUCTO ELEKTRO-L3"
case "$BASE" in
  L3_1_*) PRODUCT="ELEKTRO-L3 | CANAL 1" ;;
  L3_2_*) PRODUCT="ELEKTRO-L3 | CANAL 2" ;;
  L3_3_*) PRODUCT="ELEKTRO-L3 | CANAL 3" ;;
  L3_4_*) PRODUCT="ELEKTRO-L3 | CANAL 4" ;;
  L3_9_*) PRODUCT="ELEKTRO-L3 | CANAL 9" ;;
  msu_gs_rgb_221*) PRODUCT="MSU-GS | RGB 221 · CH2/CH2/CH1" ;;
  msu_gs_rgb_321_map*) PRODUCT="MSU-GS | RGB 321 · MAPA" ;;
  msu_gs_rgb_321*) PRODUCT="MSU-GS | RGB 321 · CH3/CH2/CH1" ;;
  msu_gs_rgb_Natural_Color_map*) PRODUCT="MSU-GS | COLOR NATURAL · MAPA" ;;
  msu_gs_rgb_Natural_Color*) PRODUCT="MSU-GS | COLOR NATURAL" ;;
  msu_gs_Thermal_Channel*) PRODUCT="MSU-GS | CANAL TÉRMICO · CH9" ;;
esac

STAMP=""
if [[ "$BASE" =~ ^L3_[0-9]+_([0-9]{8}T[0-9]{6})Z ]]; then
  STAMP="${BASH_REMATCH[1]}"
else
  for sibling in "$(dirname "$IMAGE_FILE")"/L3_[0-9]*_????????T??????Z.png; do
    if [[ "$(basename "$sibling")" =~ ^L3_[0-9]+_([0-9]{8}T[0-9]{6})Z ]]; then
      STAMP="${BASH_REMATCH[1]}"
      break
    fi
  done
fi

if [[ -n "$STAMP" ]]; then
  IMAGE_TIME="$(TZ=Europe/Madrid date -d "${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2} ${STAMP:9:2}:${STAMP:11:2}:${STAMP:13:2} UTC" '+%d/%m/%Y  %H:%M:%S')"
elif [[ "$FALLBACK_EPOCH" =~ ^[0-9]+$ ]]; then
  IMAGE_TIME="$(TZ=Europe/Madrid date -d "@$FALLBACK_EPOCH" '+%d/%m/%Y  %H:%M:%S')"
else
  IMAGE_TIME="HORA NO DISPONIBLE"
fi

STATION="${GROUND_STATION_LOCATION:-$(python3 -c 'import sys,yaml; from pathlib import Path; c=yaml.safe_load(Path(sys.argv[1]).read_text()); print(c.get("ground_station_location") or "ESTACIÓN")' "$NOAA_HOME/config/settings.yml")}"
ANTENNA="${ELEKTRO_L3_ANTENNA_INFORMATION:-$(python3 -c 'import sys,yaml; from pathlib import Path; c=yaml.safe_load(Path(sys.argv[1]).read_text()); print(c.get("elektro_l3_antenna_information") or "SAT DIY")' "$NOAA_HOME/config/settings.yml")}"

WORK_DIR="$(mktemp -d "$NOAA_HOME/tmp/elektro-header.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

HEADER_HTML="$WORK_DIR/header.html"
HEADER_PNG="$WORK_DIR/header.png"
OUTPUT_TMP="$WORK_DIR/output.png"
LOGO_URI="file://$LOGO"

python3 - "$HEADER_HTML" "$WIDTH" "$HEADER_HEIGHT" "$LOGO_URI" "$STATION" "$ANTENNA" "$PRODUCT" "$IMAGE_TIME" <<'PYHTML'
import html
import sys

path, width, height, logo, station, antenna, product, image_time = sys.argv[1:]
logo, station, antenna, product, image_time = [
    html.escape(v, quote=True)
    for v in (logo, station, antenna, product, image_time)
]

document = f"""<!doctype html>
<html><head><meta charset="utf-8"><style>
* {{ box-sizing:border-box; }}
html,body {{ margin:0; padding:0; width:{width}px; height:{height}px; overflow:hidden; }}
body {{ font-family:Arial,Helvetica,sans-serif; color:#fff; }}
.header {{
 width:100%; height:{height}px; padding:8px 26px;
 background:linear-gradient(110deg,#102e4d 0%,#0b2948 52%,#123653 100%);
 border-bottom:3px solid #19c6e3;
}}
.outer {{ width:100%; height:100%; border-collapse:collapse; table-layout:fixed; }}
.logo-cell {{ width:300px; text-align:center; vertical-align:middle; }}
.logo {{ width:294px; height:294px; object-fit:contain; position:relative; left:71px; }}
.content-cell {{ vertical-align:middle; padding-left:48px; }}
.brand {{
 height:48px; text-align:center; color:#fff;
 font-size:27px; line-height:42px; font-weight:bold;
 letter-spacing:3px; text-shadow:0 1px 3px #061a2d;
}}
.fields {{
 width:90%; height:230px; margin:0 auto; border-collapse:separate;
 border-spacing:10px 10px; table-layout:fixed;
}}
.fields td {{
 width:33.333%; height:105px; padding:9px 22px;
 vertical-align:middle; text-align:left;
 background:linear-gradient(110deg,#153b5b,#102f4d);
 border:1px solid #176486;
 border-top:2px solid #1c91b0;
}}
.label {{
 display:block; color:#42d8ed; font-size:26px;
 line-height:31px; font-weight:bold; margin-bottom:3px;
 white-space:nowrap; letter-spacing:.3px;
}}
.value {{
 display:block; color:#fff; font-size:31px;
 line-height:37px; font-weight:bold;
 white-space:nowrap;
}}
</style></head><body>
<div class="header"><table class="outer"><tr>
 <td class="logo-cell"><img class="logo" src="{logo}"></td>
 <td class="content-cell">
  <div class="brand">RASPBERRY NOAA V2</div>
  <table class="fields">
   <tr>
    <td><span class="label">Ground Station:</span><span class="value">{station}</span></td>
    <td><span class="label">Antena:</span><span class="value">{antenna}</span></td>
    <td><span class="label">Satélite:</span><span class="value">ELEKTRO-L3</span></td>
   </tr><tr>
    <td><span class="label">Fecha/hora:</span><span class="value">{image_time}</span></td>
    <td><span class="label">Ganancia:</span><span class="value">N/D</span></td>
    <td><span class="label">Imagen recibida:</span><span class="value">{product}</span></td>
   </tr>
  </table>
 </td>
</tr></table></div></body></html>"""

with open(path, "w", encoding="utf-8") as f:
    f.write(document)
PYHTML

"$WKHTMLTOIMG" --quiet --enable-local-file-access --format png \
  --width "$WIDTH" --height "$HEADER_HEIGHT" "$HEADER_HTML" "$HEADER_PNG"

"$CONVERT" "$HEADER_PNG" "$IMAGE_FILE" -append \
  -set comment "$MARKER" "$OUTPUT_TMP"

chmod --reference="$IMAGE_FILE" "$OUTPUT_TMP"
mv "$OUTPUT_TMP" "$IMAGE_FILE"

echo "Cabecera ELEKTRO añadida: $BASE (${WIDTH}x${HEADER_HEIGHT})"
