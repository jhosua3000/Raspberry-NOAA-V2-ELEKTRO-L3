.bail on
BEGIN IMMEDIATE;
ALTER TABLE decoded_passes ADD COLUMN capture_time INTEGER;
COMMIT;
