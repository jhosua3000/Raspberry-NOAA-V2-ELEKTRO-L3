#!/bin/bash
#
# apply_settings.sh
# Aplicación selectiva de config/settings.yml
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="apply_settings.sh"

MODE="check"
case "${1:---check}" in
    --check)
        MODE="check"
        ;;
    --apply)
        MODE="apply"
        ;;
    *)
        printf '[ERROR] Uso: %s [--check|--apply]\\n' "$SCRIPT_NAME" >&2
        exit 2
        ;;
esac
PROJECT_DIR="/home/$(id -un)/raspberry-noaa-v2"
SETTINGS_FILE="$PROJECT_DIR/config/settings.yml"
SCHEMA_FILE="$PROJECT_DIR/config/settings_schema.json"
VALIDATOR="$PROJECT_DIR/scripts/tools/validate_yaml.py"

log() {
    printf '[INFO] %s\n' "$1"
}

warn() {
    printf '[AVISO] %s\n' "$1" >&2
}

die() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

trap cleanup EXIT
trap 'die "Error en la línea $LINENO. No se continuará."' ERR

# --------------------------------------------------
# Comprobaciones iniciales
# --------------------------------------------------

if [[ "$EUID" -eq 0 ]]; then
    die "No ejecutes este script como root ni mediante sudo."
fi

TARGET_USER="$(id -un)"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

[[ -n "$TARGET_HOME" ]] || die "No se pudo determinar el directorio personal."
[[ "$PROJECT_DIR" == "$TARGET_HOME/raspberry-noaa-v2" ]] || \
    die "La ruta del proyecto no coincide con el directorio personal."

[[ -d "$PROJECT_DIR" ]] || die "No existe el directorio del proyecto."
[[ -f "$SETTINGS_FILE" ]] || die "No existe config/settings.yml."
[[ -f "$SCHEMA_FILE" ]] || die "No existe config/settings_schema.json."
[[ -f "$VALIDATOR" ]] || die "No existe el validador YAML."

cd "$PROJECT_DIR"

for command_name in python3 sudo; do
    command -v "$command_name" >/dev/null 2>&1 || \
        die "No está disponible el comando requerido: $command_name"
done

# --------------------------------------------------
# Validación de configuración
# --------------------------------------------------

log "Validando config/settings.yml..."

python3 "$VALIDATOR" "$SETTINGS_FILE" "$SCHEMA_FILE" || \
    die "La configuración YAML no supera la validación."

log "Validación YAML completada correctamente."

# --------------------------------------------------
# Comprobación de herramientas para aplicar plantillas
# --------------------------------------------------

for command_name in ansible-playbook php nginx; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "Falta la herramienta requerida: $command_name. No se instalará automáticamente."
    fi
done

log "Ansible, PHP y Nginx están disponibles."
if [[ "$MODE" == "check" ]]; then
    log "Modo simulación: no se aplicarán cambios."
else
    warn "Modo aplicación solicitado. Las modificaciones se realizarán únicamente mediante tareas selectivas."
fi

# --------------------------------------------------
# Directorio temporal de trabajo
# --------------------------------------------------

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apply-settings.XXXXXX")" || \
    die "No se pudo crear el directorio temporal."

chmod 0700 "$WORK_DIR"

log "Estructura inicial preparada."
log "Usuario de ejecución: $TARGET_USER"
log "Directorio del proyecto: $PROJECT_DIR"

# --------------------------------------------------
# Preparación de renderización temporal con Ansible
# --------------------------------------------------

prepare_render_playbook() {
    local playbook="$WORK_DIR/render.yml"

    cat > "$playbook" <<EOF_PLAYBOOK
---
- name: Renderizar configuraciones candidatas
  hosts: localhost
  connection: local
  gather_facts: false

  vars_files:
    - "$SETTINGS_FILE"
    - "$PROJECT_DIR/ansible/group_vars/all.yml"

  vars:
    target_user: "$TARGET_USER"
    project_dir: "$PROJECT_DIR"
    candidate_dir: "$WORK_DIR/candidates"

  tasks:
    - name: Obtener versión de Raspberry Pi OS
      command: lsb_release -cs
      register: raspbian_version
      changed_when: false

    - name: Obtener zona horaria del sistema
      command: timedatectl show --property=Timezone --value
      register: system_timezone
      changed_when: false

    - name: Crear directorio temporal de candidatos
      file:
        path: "{{ candidate_dir }}"
        state: directory
        mode: "0700"

    - name: Renderizar configuración general
      template:
        src: "{{ project_dir }}/ansible/roles/common/templates/noaa-v2.conf.j2"
        dest: "{{ candidate_dir }}/noaa-v2.conf"

    - name: Renderizar configuración Predict
      template:
        src: "{{ project_dir }}/ansible/roles/common/templates/predict.qth.j2"
        dest: "{{ candidate_dir }}/predict.qth"

    - name: Renderizar configuración WXtoImg
      template:
        src: "{{ project_dir }}/ansible/roles/common/templates/wxtoimgrc.j2"
        dest: "{{ candidate_dir }}/wxtoimgrc"

    - name: Renderizar configuración MeteorDemod
      template:
        src: "{{ project_dir }}/ansible/roles/common/templates/settings.ini.j2"
        dest: "{{ candidate_dir }}/settings.ini"

    - name: Renderizar configuración SatDump
      template:
        src: "{{ project_dir }}/ansible/roles/common/templates/satdump_cfg.json.j2"
        dest: "{{ candidate_dir }}/satdump_cfg.json"

    - name: Renderizar configuración del panel web
      template:
        src: "{{ project_dir }}/ansible/roles/webserver/templates/Config.php.j2"
        dest: "{{ candidate_dir }}/Config.php"

    - name: Renderizar configuración Nginx HTTP
      template:
        src: "{{ project_dir }}/ansible/roles/webserver/templates/nginx_default_{{ raspbian_version.stdout }}.j2"
        dest: "{{ candidate_dir }}/nginx_default"

    - name: Renderizar configuración Nginx HTTPS
      template:
        src: "{{ project_dir }}/ansible/roles/webserver/templates/nginx_tls_default_{{ raspbian_version.stdout }}.j2"
        dest: "{{ candidate_dir }}/nginx_tls_default"

    - name: Renderizar configuración NTP
      template:
        src: "{{ project_dir }}/ansible/roles/common/templates/ntp.conf.j2"
        dest: "{{ candidate_dir }}/ntp.conf"
EOF_PLAYBOOK

    chmod 0600 "$playbook"
    log "Playbook temporal de renderización preparado."
}

# --------------------------------------------------
# Validación estructural del playbook
# --------------------------------------------------

prepare_render_playbook

log "Comprobando la estructura del playbook con Ansible..."

ansible-playbook --syntax-check \
    -i 'localhost,' \
    "$WORK_DIR/render.yml" || \
    die "El playbook temporal no supera la validación de Ansible."

log "Playbook validado correctamente. No se han aplicado cambios."

# --------------------------------------------------
# Renderización temporal y validación de candidatos
# --------------------------------------------------

log "Renderizando plantillas en el directorio temporal..."

ansible-playbook \
    -i 'localhost,' \
    "$WORK_DIR/render.yml" || \
    die "Error al renderizar las plantillas."

CANDIDATE_DIR="$WORK_DIR/candidates"

log "Comprobando archivos generados..."

for file in \
    noaa-v2.conf \
    predict.qth \
    wxtoimgrc \
    settings.ini \
    satdump_cfg.json \
    Config.php \
    nginx_default \
    nginx_tls_default \
    ntp.conf
do
    [[ -s "$CANDIDATE_DIR/$file" ]] || \
        die "El archivo generado está ausente o vacío: $file"
done

log "Validando sintaxis PHP..."

php -l "$CANDIDATE_DIR/Config.php" >/dev/null || \
    die "La configuración PHP generada no es válida."

log "Validando JSON de SatDump..."

python3 "$PROJECT_DIR/scripts/tools/validate_jsonc.py" \
    "$CANDIDATE_DIR/satdump_cfg.json" || \
    die "La configuración JSONC de SatDump no es válida."

# --------------------------------------------------
# Detección selectiva de cambios
# --------------------------------------------------

CHANGED_FILES=()

compare_candidate() {
    local label="$1"
    local candidate="$2"
    local destination="$3"

    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        CHANGED_FILES+=("$label" "$candidate" "$destination")
        log "NUEVO: $label"
    elif cmp -s -- "$candidate" "$destination"; then
        log "SIN CAMBIOS: $label"
    else
        CHANGED_FILES+=("$label" "$candidate" "$destination")
        log "CAMBIO DETECTADO: $label"
    fi
}


install_atomic() {
    local label="$1" candidate="$2" destination="$3"
    local owner="$4" group="$5" mode="$6"
    local dir base temp_file

    [[ -f "$candidate" ]] || die "No existe el candidato de $label."
    dir="$(dirname "$destination")"
    base="$(basename "$destination")"
    [[ -d "$dir" ]] || die "No existe el directorio de destino de $label."
    [[ ! -L "$destination" ]] || die "Destino simbólico no permitido: $label."

    temp_file="$(sudo mktemp "$dir/.${base}.apply-settings.XXXXXX")" ||
        die "No se pudo preparar el archivo temporal de $label."

    if ! sudo install -o "$owner" -g "$group" -m "$mode" -- "$candidate" "$temp_file"; then
        sudo rm -f -- "$temp_file"
        die "No se pudo preparar la instalación de $label."
    fi

    if ! sudo mv -fT -- "$temp_file" "$destination"; then
        sudo rm -f -- "$temp_file"
        die "No se pudo sustituir el archivo de $label."
    fi

    log "INSTALADO ATÓMICAMENTE: $label"
}


apply_safe_files() {
    local i label candidate destination

    for ((i=0; i<${#CHANGED_FILES[@]}; i+=3)); do
        label="${CHANGED_FILES[i]}"
        candidate="${CHANGED_FILES[i+1]}"
        destination="${CHANGED_FILES[i+2]}"

        case "$label" in
            "Predict")
                install_atomic "$label" "$candidate" "$destination" "$TARGET_USER" "$(id -gn "$TARGET_USER")" 0644
                ;;
            "WXtoImg")
                install_atomic "$label" "$candidate" "$destination" "$TARGET_USER" "$(id -gn "$TARGET_USER")" 0644
                ;;
            "MeteorDemod")
                install_atomic "$label" "$candidate" "$destination" "$TARGET_USER" "$(id -gn "$TARGET_USER")" 0644
                ;;
            "SatDump")
                install_atomic "$label" "$candidate" "$destination" root root 0644
                ;;
            "Panel PHP")
                install_atomic "$label" "$candidate" "$destination" "$TARGET_USER" www-data 0644
                ;;
            *)
                log "PENDIENTE DE TRATAMIENTO ESPECIAL: $label"
                ;;
        esac
    done
}


apply_ntp() {
    local i label candidate destination
    local rollback_candidate="$WORK_DIR/ntp.conf.rollback"

    for ((i=0; i<${#CHANGED_FILES[@]}; i+=3)); do
        label="${CHANGED_FILES[i]}"
        candidate="${CHANGED_FILES[i+1]}"
        destination="${CHANGED_FILES[i+2]}"

        [[ "$label" == "NTP" ]] || continue

        [[ -f "$destination" ]] || die "No existe la configuración NTP actual."
        sudo cp -p -- "$destination" "$rollback_candidate" ||
            die "No se pudo preparar la restauración de NTP."

        install_atomic "NTP" "$candidate" "$destination" root root 0644

        if sudo systemctl restart ntp; then
            log "Servicio NTP reiniciado correctamente."
        else
            warn "Falló el reinicio de NTP. Restaurando la configuración anterior."
            install_atomic "Restauración NTP" "$rollback_candidate" "$destination" root root 0644

            if sudo systemctl restart ntp; then
                die "NTP recuperado con su configuración anterior. El cambio no se ha aplicado."
            else
                die "ERROR CRÍTICO: no se pudo recuperar el servicio NTP tras restaurar su configuración."
            fi
        fi
    done
}

WEB_FLAGS="$(python3 -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    settings = yaml.safe_load(f)
print(str(settings["enable_non_tls"]).lower())
print(str(settings["enable_tls"]).lower())
' "$SETTINGS_FILE")" || die "No se pudieron leer los indicadores de Nginx."

ENABLE_NON_TLS="${WEB_FLAGS%%$'\n'*}"
ENABLE_TLS="${WEB_FLAGS#*$'\n'}"

log "Comparando configuraciones generadas con las instaladas..."

compare_candidate "Configuración general" "$CANDIDATE_DIR/noaa-v2.conf" "$TARGET_HOME/.noaa-v2.conf"
compare_candidate "Predict" "$CANDIDATE_DIR/predict.qth" "$TARGET_HOME/.predict/predict.qth"
compare_candidate "WXtoImg" "$CANDIDATE_DIR/wxtoimgrc" "$TARGET_HOME/.wxtoimgrc"
compare_candidate "MeteorDemod" "$CANDIDATE_DIR/settings.ini" "$TARGET_HOME/.config/meteordemod/settings.ini"
compare_candidate "SatDump" "$CANDIDATE_DIR/satdump_cfg.json" "/usr/share/satdump/satdump_cfg.json"
compare_candidate "Panel PHP" "$CANDIDATE_DIR/Config.php" "/var/www/wx-new/Config/Config.php"

if [[ "$ENABLE_NON_TLS" == "true" ]]; then
    compare_candidate "Nginx HTTP" "$CANDIDATE_DIR/nginx_default" "/etc/nginx/sites-available/default"
else
    log "OMITIDO: Nginx HTTP está desactivado."
fi

if [[ "$ENABLE_TLS" == "true" ]]; then
    compare_candidate "Nginx HTTPS" "$CANDIDATE_DIR/nginx_tls_default" "/etc/nginx/sites-available/default-tls"
else
    log "OMITIDO: Nginx HTTPS está desactivado."
fi

compare_candidate "NTP" "$CANDIDATE_DIR/ntp.conf" "/etc/ntp.conf"

log "Renderización, validaciones y comparación completadas."

CHANGED_COUNT=$((${#CHANGED_FILES[@]} / 3))
log "Archivos nuevos o modificados detectados: $CHANGED_COUNT"

validate_apply_scope() {
    local i label candidate destination

    for ((i=0; i<${#CHANGED_FILES[@]}; i+=3)); do
        label="${CHANGED_FILES[i]}"
        candidate="${CHANGED_FILES[i+1]}"
        destination="${CHANGED_FILES[i+2]}"

        case "$label" in
            "Predict"|"WXtoImg"|"MeteorDemod"|"SatDump"|"Panel PHP"|"NTP")
                ;;
            *)
                warn "Aplicación bloqueada: '$label' todavía no tiene tratamiento autorizado."
                return 1
                ;;
        esac

        [[ -f "$candidate" ]] || {
            warn "Candidato no disponible: $label"
            return 1
        }

        [[ -d "$(dirname "$destination")" ]] || {
            warn "Directorio de destino inexistente: $label"
            return 1
        }

        [[ ! -L "$destination" ]] || {
            warn "Destino simbólico no permitido: $label"
            return 1
        }
    done
}

if [[ "$MODE" == "check" ]]; then
    log "Modo simulación finalizado. No se ha modificado el sistema."
else
    if ! validate_apply_scope; then
        die "No se ha aplicado ningún cambio: hay configuraciones pendientes de tratamiento."
    fi

    log "Validación previa superada. Aplicando únicamente archivos autorizados..."
    apply_ntp
    apply_safe_files
    log "Aplicación de configuraciones autorizadas completada."
fi
