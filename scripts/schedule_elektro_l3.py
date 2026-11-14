#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import shlex
import sqlite3
import sys
import uuid
from datetime import date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

TIMEZONE = ZoneInfo("Europe/Madrid")
SAT_NAME = "ELEKTRO-L3"
EVENT_TYPE = "GEO"
WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3,
            "fri": 4, "sat": 5, "sun": 6}


def load_config(path):
    config = {}
    with open(path, encoding="utf-8") as file:
        for line in file:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            parts = shlex.split(value, comments=False)
            config[key.strip()] = parts[0] if parts else ""
    return config


def local_datetime(day, clock, boundary="start"):
    naive = datetime.combine(day, clock)
    candidates = []

    # Comprobar las dos interpretaciones posibles de la hora local.
    for fold in (0, 1):
        value = naive.replace(tzinfo=TIMEZONE, fold=fold)
        timestamp = value.timestamp()
        roundtrip = datetime.fromtimestamp(timestamp, TIMEZONE)

        if roundtrip.replace(tzinfo=None) == naive:
            candidates.append((timestamp, value))

    if not candidates:
        raise ValueError(
            f"Hora local inexistente por cambio horario: {naive}"
        )

    # En horas normales ambas interpretaciones representan el mismo instante.
    # En horas duplicadas: inicio = primera ocurrencia, final = segunda.
    candidates.sort(key=lambda item: item[0])

    if boundary == "start":
        return candidates[0][1]

    if boundary == "end":
        return candidates[-1][1]

    raise ValueError(f"Límite horario desconocido: {boundary}")


def calculate_windows(windows, days, now):
    if days < 1:
        raise ValueError("DAYS_TO_SCHEDULE_PASSES debe ser al menos 1")

    horizon_start = now.timestamp()
    horizon_end = local_datetime(
        now.date() + timedelta(days=days - 1), time.max
    ).timestamp()

    intervals = []

    # Incluimos el día anterior para recoger ventanas que crucen medianoche.
    for offset in range(-1, days):
        start_day = now.date() + timedelta(days=offset)

        for window in windows:
            selected_days = window.get("days")
            if not isinstance(selected_days, list) or not selected_days:
                raise ValueError("Cada ventana debe indicar sus días")

            if any(day not in WEEKDAYS for day in selected_days):
                raise ValueError(f"Días no válidos: {selected_days}")

            if start_day.weekday() not in {
                WEEKDAYS[day] for day in selected_days
            }:
                continue

            start_clock = time.fromisoformat(window["start"])
            end_clock = time.fromisoformat(window["end"])

            if start_clock == end_clock:
                raise ValueError(
                    "Inicio y fin iguales no están permitidos"
                )

            end_day = start_day
            if end_clock < start_clock:
                end_day += timedelta(days=1)

            # Conservar los límites originales: pass_start identifica la ventana.
            start_ts = int(
                local_datetime(start_day, start_clock, "start").timestamp()
            )
            end_ts = int(
                local_datetime(end_day, end_clock, "end").timestamp()
            )

            # Incluir ventanas en curso y las que comienzan dentro del horizonte.
            if end_ts > horizon_start and start_ts <= horizon_end:
                intervals.append((start_ts, end_ts))

    intervals.sort()
    merged = []

    for start_ts, end_ts in intervals:
        if merged and start_ts <= merged[-1][1]:
            merged[-1] = (
                merged[-1][0], max(merged[-1][1], end_ts)
            )
        else:
            merged.append((start_ts, end_ts))

    return merged

def display_windows(intervals):
    if not intervals:
        print("No hay ventanas GEO que programar.")
        return

    for start, end in intervals:
        start_local = datetime.fromtimestamp(start, TIMEZONE)
        end_local = datetime.fromtimestamp(end, TIMEZONE)
        print(
            f"  {start_local:%a %d/%m/%Y %H:%M %Z}"
            f"  ->  {end_local:%a %d/%m/%Y %H:%M %Z}"
        )



def build_at_submission(start_ts, end_ts, now_ts, operation_id=None):
    """Prepara un trabajo at sin ejecutarlo."""
    if end_ts <= now_ts:
        raise ValueError("La ventana GEO ya ha terminado")

    receiver = Path(__file__).with_name("receive_elektro_l3.sh")
    if not receiver.is_file():
        raise RuntimeError(f"No existe el receptor: {receiver}")

    if start_ts <= now_ts:
        at_args = ["at", "now"]
    else:
        local_start = datetime.fromtimestamp(start_ts, TIMEZONE)
        at_args = ["at", "-t", local_start.strftime("%Y%m%d%H%M.%S")]

    marker = (
        f"# ELEKTRO_OPERATION_ID={operation_id}\n"
        if operation_id else ""
    )

    command = marker + (
        "now=$(date +%s); "
        f"remaining=$(({end_ts} - now)); "
        'if [ "$remaining" -gt 0 ]; then '
        f"exec /bin/bash {shlex.quote(str(receiver))} "
        f'{start_ts} "$remaining"; '
        "fi"
    )

    return at_args, command


def parse_at_job_id(output):
    """Extrae el identificador de la respuesta estándar de at."""
    match = re.search(r"\bjob\s+(\d+)\s+at\b", output)
    return int(match.group(1)) if match else None


def submit_at_job(start_ts, end_ts, now_ts, operation_id=None):
    """Crea un trabajo at y devuelve su identificador real."""
    at_args, command = build_at_submission(
        start_ts, end_ts, now_ts, operation_id
    )

    env = os.environ.copy()
    env["TZ"] = str(TIMEZONE)

    result = subprocess.run(
        at_args,
        input=command + "\n",
        text=True,
        capture_output=True,
        env=env,
        check=False
    )

    output = result.stdout + result.stderr

    if result.returncode != 0:
        raise RuntimeError(f"No se pudo crear el trabajo at: {output.strip()}")

    job_id = parse_at_job_id(output)
    if job_id is None:
        raise RuntimeError(
            f"at no devolvió un identificador reconocible: {output.strip()}"
        )

    return job_id

def get_at_queue_ids():
    """Obtiene los identificadores de trabajos pendientes en at."""
    result = subprocess.run(
        ["atq"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"No se pudo consultar atq: {result.stderr.strip()}"
        )

    return {
        int(line.split()[0])
        for line in result.stdout.splitlines()
        if line.split() and line.split()[0].isdigit()
    }


def find_at_job_by_operation_id(operation_id, queued_ids=None):
    """Localiza un trabajo pendiente mediante su marcador GEO único."""
    if not isinstance(operation_id, str) or not operation_id:
        raise ValueError("Identificador de operación no válido")

    if queued_ids is None:
        queued_ids = get_at_queue_ids()

    marker = f"# ELEKTRO_OPERATION_ID={operation_id}"
    matches = []

    for job_id in sorted(queued_ids):
        result = subprocess.run(
            ["at", "-c", str(job_id)],
            capture_output=True,
            text=True,
            check=False
        )

        if result.returncode != 0:
            raise RuntimeError(
                f"No se pudo consultar el trabajo at {job_id}: "
                f"{result.stderr.strip()}"
            )

        if any(line.strip() == marker for line in result.stdout.splitlines()):
            matches.append(job_id)

    if len(matches) > 1:
        raise RuntimeError(
            f"Marcador GEO duplicado {operation_id}: trabajos {matches}"
        )

    return matches[0] if matches else None


def cancel_at_job(job_id):
    """Cancela exclusivamente el trabajo indicado."""
    if not isinstance(job_id, int) or job_id <= 0:
        raise ValueError(f"Identificador at no válido: {job_id}")

    result = subprocess.run(
        ["atrm", str(job_id)],
        capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"No se pudo cancelar el trabajo at {job_id}: "
            f"{result.stderr.strip()}"
        )


def plan_at_reconciliation(existing, desired, now_ts, queued_ids):
    """
    Calcula la reconciliación de trabajos GEO sin modificar nada.

    existing: {pass_start: (pass_end, at_job_id)}
    desired: [(pass_start, pass_end), ...]
    queued_ids: identificadores actualmente presentes en atq
    """
    plan = {
        "create": [],
        "cancel": [],
        "update": [],
        "delete": [],
        "keep": []
    }

    desired_by_start = dict(desired)

    for start_ts, end_ts in desired:
        old = existing.get(start_ts)

        if old is None:
            plan["create"].append((start_ts, end_ts))
            plan["update"].append((start_ts, end_ts, 0))
            continue

        old_end, job_id = old

        # Una ventana en curso conserva su duración y su trabajo.
        if start_ts <= now_ts < old_end:
            if job_id == 0:
                plan["create"].append((start_ts, old_end))
                plan["update"].append((start_ts, old_end, 0))
            else:
                plan["keep"].append(start_ts)
            continue

        # Un trabajo futuro válido no necesita cambios.
        if old_end == end_ts and job_id in queued_ids:
            plan["keep"].append(start_ts)
            continue

        # Sustituir el trabajo anterior solo si sigue en la cola.
        if job_id > 0 and job_id in queued_ids:
            plan["cancel"].append(job_id)

        plan["create"].append((start_ts, end_ts))
        plan["update"].append((start_ts, end_ts, 0))

    # Eliminar solo ventanas GEO futuras que ya no estén configuradas.
    for start_ts, (end_ts, job_id) in existing.items():
        if start_ts > now_ts and start_ts not in desired_by_start:
            if job_id > 0 and job_id in queued_ids:
                plan["cancel"].append(job_id)
            plan["delete"].append(start_ts)

    return plan


def journal_validate_schema(conn):
    """Comprueba que el diario GEO tiene las columnas necesarias."""
    required = {
        "operation_id", "pass_start", "action",
        "old_job_id", "new_job_id", "status",
        "created_at", "updated_at", "last_error",
        "new_pass_end", "old_pass_end"
    }
    rows = conn.execute(
        "PRAGMA table_info(elektro_at_operations)"
    ).fetchall()
    found = {row[1] for row in rows}
    missing = required - found

    if missing:
        raise RuntimeError(
            f"El diario GEO no tiene las columnas necesarias: {sorted(missing)}"
        )


def journal_insert_operation(
    conn, operation_id, pass_start, action,
    old_job_id=0, new_pass_end=None, old_pass_end=None
):
    """Registra una operación antes de realizar cambios externos."""
    if action not in ("CREATE", "REPLACE", "DELETE"):
        raise ValueError(f"Acción GEO no válida: {action}")

    conn.execute(
        """
        INSERT INTO elektro_at_operations
        (operation_id, pass_start, action, old_job_id,
         new_job_id, status, new_pass_end, old_pass_end)
        VALUES (?, ?, ?, ?, 0, 'PREPARED', ?, ?)
        """,
        (
            operation_id, pass_start, action,
            old_job_id, new_pass_end, old_pass_end
        )
    )


def journal_set_status(
    conn, operation_id, new_status,
    new_job_id=None, last_error=None
):
    """Actualiza el estado del diario validando la transición."""
    transitions = {
        "PREPARED": {"NEW_SUBMITTED", "OLD_CANCELLED", "DB_COMMITTED", "ERROR"},
        "NEW_SUBMITTED": {"OLD_CANCELLED", "DB_COMMITTED", "ERROR"},
        "OLD_CANCELLED": {"DB_COMMITTED", "ERROR"},
        "DB_COMMITTED": {"DONE", "ERROR"},
        "ERROR": {
            "PREPARED", "NEW_SUBMITTED",
            "OLD_CANCELLED", "DB_COMMITTED"
        },
        "DONE": set()
    }

    row = conn.execute(
        "SELECT status FROM elektro_at_operations WHERE operation_id = ?",
        (operation_id,)
    ).fetchone()

    if row is None:
        raise RuntimeError(
            f"No existe la operación GEO {operation_id}"
        )

    old_status = row[0]
    if new_status not in transitions.get(old_status, set()):
        raise RuntimeError(
            f"Transición GEO no permitida: {old_status} -> {new_status}"
        )

    if new_job_id is None:
        conn.execute(
            """
            UPDATE elektro_at_operations
            SET status = ?, last_error = ?, updated_at = strftime('%s', 'now')
            WHERE operation_id = ?
            """,
            (new_status, last_error, operation_id)
        )
    else:
        conn.execute(
            """
            UPDATE elektro_at_operations
            SET status = ?, new_job_id = ?, last_error = ?,
                updated_at = strftime('%s', 'now')
            WHERE operation_id = ?
            """,
            (new_status, new_job_id, last_error, operation_id)
        )


def journal_pending_operations(conn):
    """Devuelve las operaciones GEO que todavía no están terminadas."""
    cursor = conn.execute(
        """
        SELECT operation_id, pass_start, action,
               old_job_id, new_job_id, status,
               created_at, updated_at, last_error,
               new_pass_end, old_pass_end
        FROM elektro_at_operations
        WHERE status != 'DONE'
        ORDER BY created_at, pass_start
        """
    )
    columns = [item[0] for item in cursor.description]
    return [
        dict(zip(columns, row))
        for row in cursor.fetchall()
    ]


def plan_journal_recovery(operation, now_ts, queued_ids,
                           marker_job_id=None):
    """Decide cómo recuperar una operación GEO sin ejecutar acciones."""
    status = operation["status"]
    action = operation["action"]
    start_ts = operation["pass_start"]
    end_ts = operation["new_pass_end"]
    old_job_id = operation["old_job_id"]
    new_job_id = operation["new_job_id"]

    if status == "DONE":
        return "NONE"

    if status == "DB_COMMITTED":
        return "MARK_DONE"

    if status == "ERROR":
        return "MANUAL_REVIEW"

    if status not in (
        "PREPARED", "NEW_SUBMITTED", "OLD_CANCELLED"
    ):
        raise ValueError(f"Estado GEO desconocido: {status}")

    if action == "DELETE":
        # Nunca modificar una operación DELETE cuya ventana ya comenzó.
        if now_ts >= start_ts:
            return "MANUAL_REVIEW"
        if old_job_id > 0 and old_job_id in queued_ids:
            return "CANCEL_OLD"
        return "COMMIT_DELETE"

    if action not in ("CREATE", "REPLACE"):
        raise ValueError(f"Acción GEO desconocida: {action}")

    if end_ts is None or end_ts <= start_ts:
        raise ValueError("La operación GEO no tiene una ventana válida")

    if new_job_id == 0:
        if marker_job_id is not None:
            return "ADOPT_NEW"
        # También se permite recuperar una ventana que ya ha comenzado
        # pero todavía está dentro de su periodo de validez.
        if now_ts < end_ts:
            return "SUBMIT_NEW"
        return "MANUAL_REVIEW"

    # Un trabajo ausente de at antes del inicio requiere revisión.
    if new_job_id not in queued_ids and now_ts < start_ts:
        return "MANUAL_REVIEW"

    if action == "REPLACE" and old_job_id > 0:
        if old_job_id in queued_ids:
            return "CANCEL_OLD"

    return "COMMIT_UPSERT"



def recover_journal_operations(database, now_ts):
    """Recupera operaciones GEO pendientes usando el diario transaccional."""
    recovered = 0

    while True:
        conn = sqlite3.connect(database)
        try:
            journal_validate_schema(conn)
            pending = journal_pending_operations(conn)
        finally:
            conn.close()

        if not pending:
            return recovered

        operation = pending[0]
        operation_id = operation["operation_id"]
        action = operation["action"]
        old_job_id = operation["old_job_id"]
        new_job_id = operation["new_job_id"]

        queued_ids = get_at_queue_ids()

        marker_job_id = None
        if action in ("CREATE", "REPLACE") and new_job_id == 0:
            marker_job_id = find_at_job_by_operation_id(
                operation_id, queued_ids
            )

        decision = plan_journal_recovery(
            operation, now_ts, queued_ids, marker_job_id
        )

        if decision == "MANUAL_REVIEW":
            raise RuntimeError(
                f"Operación GEO {operation_id} requiere revisión manual "
                f"(acción={action}, estado={operation['status']})"
            )

        if decision == "NONE":
            return recovered

        if decision == "MARK_DONE":
            conn = sqlite3.connect(database)
            try:
                conn.execute("BEGIN IMMEDIATE")
                journal_set_status(conn, operation_id, "DONE")
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()

            recovered += 1
            continue

        if decision == "SUBMIT_NEW":
            new_job_id = submit_at_job(
                operation["pass_start"],
                operation["new_pass_end"],
                now_ts,
                operation_id
            )

            conn = sqlite3.connect(database)
            try:
                conn.execute("BEGIN IMMEDIATE")
                journal_set_status(
                    conn, operation_id, "NEW_SUBMITTED",
                    new_job_id=new_job_id
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()

            continue

        if decision == "ADOPT_NEW":
            conn = sqlite3.connect(database)
            try:
                conn.execute("BEGIN IMMEDIATE")
                journal_set_status(
                    conn, operation_id, "NEW_SUBMITTED",
                    new_job_id=marker_job_id
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()

            continue

        if decision == "CANCEL_OLD":
            if old_job_id > 0 and old_job_id in queued_ids:
                cancel_at_job(old_job_id)

            conn = sqlite3.connect(database)
            try:
                conn.execute("BEGIN IMMEDIATE")
                journal_set_status(
                    conn, operation_id, "OLD_CANCELLED"
                )
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()

            continue

        if decision not in ("COMMIT_DELETE", "COMMIT_UPSERT"):
            raise RuntimeError(
                f"Decisión de recuperación desconocida: {decision}"
            )

        conn = sqlite3.connect(database)
        try:
            conn.execute("BEGIN IMMEDIATE")

            current = conn.execute(
                """
                SELECT sat_name, event_type, pass_end, at_job_id
                FROM predict_passes
                WHERE pass_start = ?
                """,
                (operation["pass_start"],)
            ).fetchone()

            if current is not None and (
                current[0] != SAT_NAME or current[1] != EVENT_TYPE
            ):
                raise RuntimeError(
                    f"Colisión GEO en pass_start={operation['pass_start']}"
                )

            if decision == "COMMIT_DELETE":
                if current is None:
                    raise RuntimeError(
                        "La ventana GEO que debía eliminarse ya no existe"
                    )

                if (
                    int(current[3]) != old_job_id
                    or int(current[2]) != operation["old_pass_end"]
                ):
                    raise RuntimeError(
                        "El registro GEO cambió antes de eliminarlo"
                    )

                conn.execute(
                    """
                    DELETE FROM predict_passes
                    WHERE pass_start = ?
                      AND sat_name = ? AND event_type = ?
                    """,
                    (operation["pass_start"], SAT_NAME, EVENT_TYPE)
                )

            else:
                if action == "CREATE":
                    if current is not None:
                        raise RuntimeError(
                            "Ya existe un registro en el inicio GEO que "
                            "debía crearse"
                        )

                    conn.execute(
                        """
                        INSERT INTO predict_passes (
                            sat_name, pass_start, pass_end, max_elev,
                            is_active, pass_start_azimuth, direction,
                            azimuth_at_max, at_job_id, event_type
                        )
                        VALUES (?, ?, ?, NULL, 1, NULL, NULL, NULL, ?, ?)
                        """,
                        (
                            SAT_NAME,
                            operation["pass_start"],
                            operation["new_pass_end"],
                            new_job_id,
                            EVENT_TYPE
                        )
                    )

                elif action == "REPLACE":
                    if current is None:
                        raise RuntimeError(
                            "No existe la ventana GEO que debía sustituirse"
                        )

                    if (
                        int(current[3]) != old_job_id
                        or int(current[2]) != operation["old_pass_end"]
                    ):
                        raise RuntimeError(
                            "El registro GEO cambió antes de sustituirlo"
                        )

                    conn.execute(
                        """
                        UPDATE predict_passes
                        SET pass_end = ?, at_job_id = ?
                        WHERE pass_start = ?
                          AND sat_name = ? AND event_type = ?
                        """,
                        (
                            operation["new_pass_end"],
                            new_job_id,
                            operation["pass_start"],
                            SAT_NAME,
                            EVENT_TYPE
                        )
                    )

                else:
                    raise RuntimeError(
                        f"Acción GEO inesperada al confirmar: {action}"
                    )

            journal_set_status(conn, operation_id, "DB_COMMITTED")
            conn.commit()

        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

        recovered += 1

def update_database(database, intervals, now):
    """
    Sincroniza las ventanas GEO mediante el diario transaccional.
    Cada operación externa queda registrada antes de ejecutarse.
    """
    now_ts = int(now.timestamp())
    desired = list(intervals)

    def read_geo_snapshot(conn):
        return {
            int(row[0]): (int(row[1]), int(row[2]))
            for row in conn.execute(
                """
                SELECT pass_start, pass_end, at_job_id
                FROM predict_passes
                WHERE sat_name = ? AND event_type = ?
                """,
                (SAT_NAME, EVENT_TYPE)
            )
        }

    def check_collision(conn, start_ts):
        conflict = conn.execute(
            """
            SELECT sat_name, event_type
            FROM predict_passes
            WHERE pass_start = ?
              AND NOT (sat_name = ? AND event_type = ?)
            """,
            (start_ts, SAT_NAME, EVENT_TYPE)
        ).fetchone()

        if conflict:
            raise RuntimeError(
                f"Colisión en pass_start={start_ts}: {conflict}"
            )

    # Recuperar primero cualquier operación interrumpida anteriormente.
    recover_journal_operations(database, now_ts)

    # Validar intervalos antes de iniciar una nueva reconciliación.
    if len({start for start, _ in desired}) != len(desired):
        raise RuntimeError("Hay inicios de ventana GEO duplicados")

    if any(end <= start for start, end in desired):
        raise RuntimeError("Hay una ventana GEO con duración no válida")

    conn = sqlite3.connect(database)
    try:
        conn.execute("BEGIN")

        columns = {
            row[1] for row in conn.execute(
                "PRAGMA table_info(predict_passes)"
            )
        }
        if not {"event_type", "at_job_id"}.issubset(columns):
            raise RuntimeError(
                "Faltan event_type o at_job_id en predict_passes"
            )

        journal_validate_schema(conn)
        existing = read_geo_snapshot(conn)

        job_ids = [
            job_id for _, job_id in existing.values()
            if job_id > 0
        ]
        if len(job_ids) != len(set(job_ids)):
            raise RuntimeError(
                "Hay identificadores at duplicados entre ventanas GEO"
            )

        for start_ts, _ in desired:
            check_collision(conn, start_ts)

        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    # El plan solo decide qué operaciones hacen falta.
    # No crea ni cancela trabajos directamente.
    queued_ids = get_at_queue_ids()
    plan = plan_at_reconciliation(
        existing, desired, now_ts, queued_ids
    )

    def execute_journaled_operation(
        action, start_ts, end_ts, expected
    ):
        operation_id = str(uuid.uuid4())

        if action == "CREATE":
            old_job_id = 0
            old_pass_end = None
        elif action == "REPLACE":
            if start_ts not in expected:
                raise RuntimeError(
                    f"No existe la ventana que se pretende sustituir: "
                    f"{start_ts}"
                )
            old_pass_end, old_job_id = expected[start_ts]
        elif action == "DELETE":
            if start_ts not in expected:
                raise RuntimeError(
                    f"No existe la ventana que se pretende eliminar: "
                    f"{start_ts}"
                )
            old_pass_end, old_job_id = expected[start_ts]
            end_ts = None
        else:
            raise ValueError(f"Acción no válida: {action}")

        # Registrar la operación de forma atómica y comprobar
        # que la fotografía GEO no ha cambiado.
        conn = sqlite3.connect(database)
        try:
            conn.execute("BEGIN IMMEDIATE")
            journal_validate_schema(conn)

            current = read_geo_snapshot(conn)
            if current != expected:
                raise RuntimeError(
                    "Los registros GEO cambiaron durante la "
                    "reconciliación. Se detiene el proceso."
                )

            if action != "DELETE":
                check_collision(conn, start_ts)

            journal_insert_operation(
                conn,
                operation_id,
                start_ts,
                action,
                old_job_id=old_job_id,
                new_pass_end=end_ts,
                old_pass_end=old_pass_end
            )
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

        # La recuperación ejecuta at y confirma SQLite.
        # Si falla, el diario conserva la operación pendiente.
        recover_journal_operations(database, now_ts)

        # Comprobar que la operación terminó correctamente.
        conn = sqlite3.connect(database)
        try:
            journal_row = conn.execute(
                """
                SELECT status, new_job_id
                FROM elektro_at_operations
                WHERE operation_id = ?
                """,
                (operation_id,)
            ).fetchone()

            if journal_row is None or journal_row[0] != "DONE":
                status = journal_row[0] if journal_row else "NO ENCONTRADA"
                raise RuntimeError(
                    f"La operación {operation_id} no terminó: {status}"
                )

            pending = journal_pending_operations(conn)
            if pending:
                raise RuntimeError(
                    "Quedan operaciones GEO pendientes tras la recuperación"
                )

            updated = read_geo_snapshot(conn)

            # Verificar que las demás ventanas no han cambiado.
            expected_other = {
                key: value for key, value in expected.items()
                if key != start_ts
            }
            updated_other = {
                key: value for key, value in updated.items()
                if key != start_ts
            }

            if updated_other != expected_other:
                raise RuntimeError(
                    "Han cambiado otras ventanas GEO durante la operación"
                )

            if action == "DELETE":
                if start_ts in updated:
                    raise RuntimeError(
                        f"No se eliminó la ventana GEO {start_ts}"
                    )
            else:
                target = updated.get(start_ts)
                if (
                    target is None
                    or target[0] != end_ts
                    or target[1] <= 0
                ):
                    raise RuntimeError(
                        f"Resultado inesperado para la ventana GEO "
                        f"{start_ts}: {target}"
                    )

            return updated
        finally:
            conn.close()

    # Crear o sustituir primero. Las sustituciones conservan
    # el valor anterior para que la recuperación pueda hacer CAS.
    for start_ts, end_ts in plan["create"]:
        action = "REPLACE" if start_ts in existing else "CREATE"

        existing = execute_journaled_operation(
            action, start_ts, end_ts, existing
        )

    # Eliminar después las ventanas futuras que ya no se desean.
    for start_ts in plan["delete"]:
        existing = execute_journaled_operation(
            "DELETE", start_ts, None, existing
        )

    print(
        f"Reconciliación GEO completada: "
        f"{len(desired)} ventanas deseadas; "
        f"{len(plan['create'])} operaciones de creación/sustitución; "
        f"{len(plan['delete'])} eliminaciones."
    )

def self_test():
    test_windows = [
        {
            "days": ["mon"],
            "start": "08:00",
            "end": "09:00"
        },
        {
            "days": ["mon"],
            "start": "09:00",
            "end": "10:00"
        },
        {
            "days": ["mon"],
            "start": "08:30",
            "end": "09:30"
        },
        {
            "days": ["mon"],
            "start": "23:00",
            "end": "01:00"
        }
    ]

    now = datetime(2026, 11, 9, 7, 0, tzinfo=TIMEZONE)
    result = calculate_windows(test_windows, 2, now)

    expected = [
        (
            local_datetime(date(2026, 11, 9), time(8, 0)).timestamp(),
            local_datetime(date(2026, 11, 9), time(10, 0)).timestamp()
        ),
        (
            local_datetime(date(2026, 11, 9), time(23, 0)).timestamp(),
            local_datetime(date(2026, 11, 10), time(1, 0)).timestamp()
        )
    ]

    assert result == [(int(a), int(b)) for a, b in expected]

    # Una ventana en curso debe conservar su inicio original.
    stable_window = [
        {"days": ["mon"], "start": "08:00", "end": "09:30"}
    ]
    first_run = calculate_windows(
        stable_window, 1,
        datetime(2026, 11, 9, 8, 15, tzinfo=TIMEZONE)
    )
    second_run = calculate_windows(
        stable_window, 1,
        datetime(2026, 11, 9, 8, 45, tzinfo=TIMEZONE)
    )
    assert first_run == second_run
    assert first_run[0][0] == int(
        local_datetime(date(2026, 11, 9), time(8, 0)).timestamp()
    )

    # Otoño: incluir las dos ocurrencias de la hora duplicada.
    autumn = calculate_windows(
        [{"days": ["sun"], "start": "02:15", "end": "02:45"}],
        1,
        datetime(2026, 10, 25, 0, 0, tzinfo=TIMEZONE)
    )
    assert len(autumn) == 1
    assert autumn[0][1] - autumn[0][0] == 90 * 60

    # Primavera: rechazar una hora local que no existe.
    try:
        calculate_windows(
            [{"days": ["sun"], "start": "02:30", "end": "03:30"}],
            1,
            datetime(2027, 3, 28, 0, 0, tzinfo=TIMEZONE)
        )
    except ValueError as error:
        assert "inexistente" in str(error)
    else:
        raise AssertionError("No se rechazó la hora inexistente de primavera")

    print("OK: solapamientos, ventanas contiguas y medianoche.")
    print("OK: otoño: se incluyen las dos ocurrencias de la hora duplicada.")
    print("OK: primavera: se rechazan las horas locales inexistentes.")


def main():
    parser = argparse.ArgumentParser(
        description="Programador de ventanas GEO Elektro-L3"
    )
    parser.add_argument(
        "--config",
        default=str(Path.home() / ".noaa-v2.conf")
    )
    parser.add_argument(
        "--now",
        help="Fecha/hora de prueba ISO 8601"
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Escribir los cambios en SQLite"
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Ejecutar pruebas internas sin leer configuración"
    )
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    config = load_config(args.config)

    required = [
        "DB_FILE",
        "DAYS_TO_SCHEDULE_PASSES",
        "ELEKTRO_L3_SCHEDULE",
        "ELEKTRO_L3_SCHEDULE_WINDOWS"
    ]
    missing = [key for key in required if key not in config]
    if missing:
        raise RuntimeError(
            "Faltan variables de configuración: " + ", ".join(missing)
            + ". Despliega primero la plantilla Ansible."
        )

    days = int(config["DAYS_TO_SCHEDULE_PASSES"])
    enabled_value = config["ELEKTRO_L3_SCHEDULE"].strip().lower()

    if enabled_value not in ("true", "false"):
        raise ValueError(
            "ELEKTRO_L3_SCHEDULE debe ser true o false"
        )

    enabled = enabled_value == "true"

    if enabled:
        windows = json.loads(config["ELEKTRO_L3_SCHEDULE_WINDOWS"])

        if not isinstance(windows, list):
            raise ValueError(
                "ELEKTRO_L3_SCHEDULE_WINDOWS debe ser una lista"
            )

        if not windows:
            raise ValueError(
                "L3 está habilitado, pero no hay ventanas configuradas. "
                "No se modificará la base de datos."
            )
    else:
        print("Programación Elektro-L3 desactivada.")
        windows = []

    if args.now:
        now = datetime.fromisoformat(args.now)

        if now.tzinfo is None:
            raise ValueError(
                "--now debe incluir zona horaria u offset, "
                "por ejemplo 2026-11-08T00:30:00+01:00"
            )

        now = now.astimezone(TIMEZONE)
    else:
        now = datetime.now(TIMEZONE)

    intervals = calculate_windows(windows, days, now)

    print(f"Satélite: {SAT_NAME}")
    print(f"Programación habilitada: {enabled}")
    print(f"Horizonte: {days} días")
    print(f"Zona horaria: {TIMEZONE}")
    print(f"Desde: {now:%d/%m/%Y %H:%M:%S %Z}")
    print("\nVentanas calculadas:")
    display_windows(intervals)

    if not args.apply:
        print("\nSIMULACIÓN: no se ha modificado la base de datos.")
        print("Para aplicar los cambios se requiere --apply.")
        return

    update_database(config["DB_FILE"], intervals, now)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
