# Backup, recovery and document storage guide

This guide covers recovery for a school administrator. Store backups outside the computer that runs the School Hub and keep backup passwords separately.

## Create a transfer backup

1. Sign in to the School desktop app and open **Hub & backups**.
2. Choose **Create encrypted backup**.
3. Enter and confirm a passphrase with at least 12 characters. Save it in a password manager or another secure place; support staff cannot recover a forgotten passphrase.
4. Keep the downloaded `.schoolbackup` file on a separate drive or other protected location.

The encrypted transfer file uses AES-256-GCM with a passphrase-derived key. The current import limit is 1 GiB. Transfer files include the local database and school identity. They exclude user accounts, passwords, sessions, paired-device secrets, pending sync queues and signed license tokens. A new administrator account and license activation are required after transfer. Uploaded school documents are stored outside the database and are not included in this first transfer format; copy them separately only through an approved protected process.

## Restore on a replacement computer

1. Install and start the School Hub and desktop app, then complete the initial setup with a temporary administrator account.
2. Open **Hub & backups** and choose **Restore encrypted backup from file**.
3. Select the `.schoolbackup` file, enter its passphrase, and confirm the replacement. The current database is saved as a local recovery point first.
4. When the app restarts, create a new school administrator account. Re-enroll devices and reconnect the license with the platform team.
5. Verify the school name, class and student counts, then reconnect mobile devices and the optional relay.

The Hub checks the passphrase, encrypted-file integrity, database integrity, schema version and embedded school identity before replacing its database. A wrong passphrase or a damaged file is rejected without replacing the current database.

## Restore a local recovery point

The Hub creates a local SQLite recovery snapshot on first setup and then automatically, every 24 hours by default. It keeps the newest 30 snapshots by default. `HUB_BACKUP_INTERVAL_HOURS` (1–720 hours) and `HUB_BACKUP_RETENTION_COUNT` (1–365) configure the schedule and count. The backup list shows snapshots stored on the same computer. Choose **Restore** beside a snapshot. The Hub first saves a recovery copy of its current database. After the restore, sign in again because active sessions are cleared.

Local snapshots are not encrypted in this version. They contain school records and account password hashes. Protect the School ERP data folder with the computer's operating-system account and full-disk encryption. Do not send a local `.sqlite` snapshot to another person; use the encrypted `.schoolbackup` export instead.

## School document storage

Open **Hub & backups → School document storage** to review use, upload, download or permanently delete files.

- Accepted formats: PDF, JPG/JPEG, PNG, and macro-free DOCX, XLSX and PPTX. The Hub inspects file contents rather than trusting the file name or browser MIME header.
- The default per-file limit is 25 MiB. The local `.env` setting `SCHOOL_ERP_MAX_FILE_BYTES` can lower it or raise it to at most 100 MiB.
- The default school document quota is 50 GiB. `SCHOOL_ERP_STORAGE_QUOTA_BYTES` can reduce this cap; it cannot raise it above 50 GiB. Usage counts stored (compressed) bytes for the local document library. The local database, recovery snapshots and log files are outside this file quota.
- Identical file contents are stored once. Lossless gzip compression is kept only when it reduces the stored size. Downloads are checksum-verified.
- Deleting a file from this page permanently removes it and releases its quota. Choose and document the school's retention policy before uploading student records.

This document library is not linked to student or staff records yet. The separate past-session archive and paid, filtered archive-query workflow are not implemented. Do not use document deletion controls as a substitute for those archives.

## Recovery drills

At least once before a pilot and after a backup-format change, use synthetic data to:

1. Create a transfer backup and verify that an incorrect passphrase is rejected.
2. Restore the valid transfer backup in a fresh local setup and compare the school identity and key record counts.
3. Confirm that a new administrator is required and that the old session cannot access the restored Hub.
4. Restore a same-computer recovery point and confirm the recovery copy remains listed.
5. Verify file checksums by downloading a stored test document, then delete it and confirm quota usage drops.

See the [Phase 10 acceptance report](../phase10-acceptance.md) for the last recorded test results and remaining limits.
