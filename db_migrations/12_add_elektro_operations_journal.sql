.bail on
BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS elektro_at_operations (
    operation_id TEXT PRIMARY KEY NOT NULL,
    pass_start INTEGER NOT NULL,
    action TEXT NOT NULL
        CHECK (action IN ('CREATE', 'REPLACE', 'DELETE')),
    old_job_id INTEGER NOT NULL DEFAULT 0,
    new_job_id INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL
        CHECK (status IN (
            'PREPARED',
            'NEW_SUBMITTED',
            'OLD_CANCELLED',
            'DB_COMMITTED',
            'DONE',
            'ERROR'
        )),
    created_at INTEGER NOT NULL
        DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL
        DEFAULT (strftime('%s', 'now')),
    last_error TEXT,
    new_pass_end INTEGER,
    old_pass_end INTEGER
);

CREATE INDEX IF NOT EXISTS idx_elektro_at_operations_status
ON elektro_at_operations (status, created_at, pass_start);

COMMIT;
