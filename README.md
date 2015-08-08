This script creates backups for PostgreSQL databases suitable for restoration by pg_restore
It is most commonly used on smaller databases, via cron.

pg_restore is a flexible format that allows for text restores, reordering, and adjusting as needed via
a manifest stored within the backup. If you have questions, consult the documentation for your version of 
PostgreSQL at https://www.postgresql.org or man pg_restore.

Modify the configuration section to suit your environment if needed. Outside of that section, you shouldn't
have to change anything.

These backups are automatically compressed in tar.gz format, per the pg_dump custom format.
This allows one to dump a manifest of the backup, and restore parts if needed. It allows for much
greater control over backups than the plain text format.

Globals are also backed up, in uncompressed format. Globals are usually very small and generally
consist of tablespace definitions, user definitions, and alter statements.

The backups will automatically be rotated once a week, via date 
(the DATESTAMP variable ensures this, since Sat backups will be overwritten every Saturday) 
so there will (hopefully) be no disk space issues because of uncompressed backups or unrotated/deleted backups.
Be sure to move these off the server to your backup server, of course. =) 

If you change the datestamp, you will change this autorotating behavior. BEWARE. =)
