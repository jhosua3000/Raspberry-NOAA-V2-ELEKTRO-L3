.bail on

BEGIN IMMEDIATE;

CREATE TABLE predict_passes_new (
    sat_name TEXT NOT NULL,
    pass_start TIMESTAMP PRIMARY KEY
        DEFAULT (strftime('%s', 'now')) NOT NULL,
    pass_end TIMESTAMP
        DEFAULT (strftime('%s', 'now')),
    max_elev INT,
    is_active BOOLEAN,
    pass_start_azimuth INT,
    direction TEXT,
    azimuth_at_max INT,
    at_job_id INT NOT NULL DEFAULT 0,
    event_type TEXT NOT NULL DEFAULT 'ORBITAL'
        CHECK (event_type IN ('ORBITAL', 'GEO'))
);

INSERT INTO predict_passes_new (
    sat_name,
    pass_start,
    pass_end,
    max_elev,
    is_active,
    pass_start_azimuth,
    direction,
    azimuth_at_max,
    at_job_id,
    event_type
)
SELECT
    sat_name,
    pass_start,
    pass_end,
    max_elev,
    is_active,
    pass_start_azimuth,
    direction,
    azimuth_at_max,
    at_job_id,
    'ORBITAL'
FROM predict_passes;

DROP TABLE predict_passes;

ALTER TABLE predict_passes_new RENAME TO predict_passes;

COMMIT;
