#!/usr/bin/env python3

"""Select non-conflicting future Meteor passes, prioritizing ELEKTRO-L3 GEO."""

import os
import sqlite3
import subprocess
import sys
import time

METEOR_SATELLITES = ("METEOR-M2 3", "METEOR-M2 4")


def cancel_at_job(job_id):
    """Cancel exactly the requested at job."""
    if not job_id or int(job_id) <= 0:
        print("ERROR: missing or invalid at_job_id; keeping database row")
        return False

    result = subprocess.run(
        ["atrm", str(int(job_id))],
        capture_output=True,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        print(
            f"ERROR: cannot confirm cancellation of at job {job_id}: "
            f"{result.stderr.strip()}"
        )
        return False

    print(f"Cancelled at job {job_id}")
    return True


def delete_pass(cursor, conn, sat_name, pass_start, event_type, job_id):
    """Delete the matching DB row only after successful job cancellation."""
    if not cancel_at_job(job_id):
        return False

    cursor.execute(
        """
        DELETE FROM predict_passes
        WHERE sat_name = ? AND pass_start = ? AND event_type = ?
        """,
        (sat_name, pass_start, event_type),
    )

    if cursor.rowcount != 1:
        conn.rollback()
        print(
            f"ERROR: job {job_id} cancelled, but matching database row "
            f"was not deleted: {sat_name}, {pass_start}"
        )
        return False

    conn.commit()
    return True


def overlaps(start_a, end_a, start_b, end_b):
    return (
        end_a is not None
        and end_b is not None
        and start_a < end_b
        and end_a > start_b
    )


def remove_meteor_overlapping_geo(cursor, conn, now):
    """ELEKTRO-L3 GEO windows have priority over future Meteor passes."""
    cursor.execute(
        """
        SELECT pass_start, pass_end
        FROM predict_passes
        WHERE sat_name = 'ELEKTRO-L3'
          AND event_type = 'GEO'
        ORDER BY pass_start
        """
    )
    geo_windows = cursor.fetchall()

    cursor.execute(
        """
        SELECT sat_name, pass_start, pass_end, max_elev, at_job_id
        FROM predict_passes
        WHERE event_type = 'ORBITAL'
          AND sat_name IN (?, ?)
          AND pass_start > ?
        ORDER BY pass_start
        """,
        (*METEOR_SATELLITES, now),
    )
    meteor_passes = cursor.fetchall()

    for sat_name, start, end, _elevation, job_id in meteor_passes:
        if any(
            overlaps(start, end, geo_start, geo_end)
            for geo_start, geo_end in geo_windows
        ):
            print(
                f"ELEKTRO-L3 GEO priority: removing {sat_name} "
                f"pass at {start}, at job {job_id}"
            )
            delete_pass(cursor, conn, sat_name, start, "ORBITAL", job_id)


def main():
    if len(sys.argv) != 3:
        print(
            f"Usage: {sys.argv[0]} "
            "<database_path> <select_meteor_pass_over_noaa>"
        )
        return 1

    database_path = os.path.expanduser(sys.argv[1])

    # Retained for compatibility with schedule.sh.
    # NOAA 15/18/19 are retired and excluded from this selector.
    _legacy_noaa_setting = sys.argv[2].lower() == "true"

    conn = sqlite3.connect(database_path)

    try:
        cursor = conn.cursor()
        now = int(time.time())

        remove_meteor_overlapping_geo(cursor, conn, now)

        print("Finished ELEKTRO-L3 GEO and Meteor overlap selection.")

    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
