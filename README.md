# backup-automation

A bash backup job that implements the 3-2-1 rule properly: three copies, two media, one offsite,
with rotation, checksums and a restore drill. Plus systemd timers so it runs itself and a test
suite so I know it works.

Written after I found out my old "backup" was a cron job with a `tar` command and no error
checking, which had been failing silently for weeks.

## What a run does

1. Takes a lock, so two runs can never fight over the same directory.
2. Archives each configured source, applying the exclude patterns.
3. Writes a SHA-256 next to each archive.
4. Verifies the checksum and reads the archive index back.
5. Copies to the second medium and **verifies again there**, on the far side of the copy.
6. Pushes offsite with rsync or rclone.
7. Prunes each rotation tier independently.
8. Writes a state file with the result, for monitoring to pick up.

Every step that fails changes the exit code, and the script keeps going with the rest rather than
dying halfway through:

| Code | Meaning |
|---|---|
| 0 | everything worked |
| 1 | configuration missing or invalid |
| 2 | an archive failed verification |
| 3 | another run holds the lock |
| 4 | a configured source does not exist |
| 5 | the second copy failed or its target is not mounted |
| 6 | the offsite push failed |

That granularity matters when a monitoring check looks at the exit code. "The offsite copy
failed" and "the archive is corrupt" need very different responses.

## Setting it up

```bash
cp etc/backup.conf.example etc/backup.conf
$EDITOR etc/backup.conf
./bin/backup.sh
```

The config is plain shell variables:

```bash
JOB_NAME="homelab"
SOURCES="/etc /home/arc/projects /var/lib/docker/volumes"
EXCLUDES="*.tmp *.log node_modules .cache __pycache__ .venv"
PRIMARY_DIR="/srv/backups"
SECONDARY_DIR="/mnt/usb-backup"
REMOTE_TARGET="backup@offsite.example.net:/srv/backups/homelab"
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6
```

Install it as a pair of systemd timers, nightly backup and weekly verification, with the commands
in [docs/3-2-1.md](docs/3-2-1.md).

## Checking and restoring

```bash
./bin/verify.sh              # checksums and archive structure
./bin/verify.sh --drill      # also extracts the newest archive into a temp directory
./bin/restore.sh --list
./bin/restore.sh --to /tmp/restore-check
```

`restore.sh` checks the checksum before extracting and refuses to write into a directory that
already has files in it.

## Tests

```bash
./tests/test_backup.sh
```

22 assertions against real temporary directories. No mocks, it makes actual archives and restores
them. What it covers:

- files land in both copies, with checksums
- exclude patterns are honoured
- a corrupted archive is detected, and the message says the checksum did not match
- a restored file is byte identical to the original, binary content included
- rotation trims to the configured count and keeps the newest
- a second run refuses to start while the lock is held
- a missing source and an unmounted second medium both exit non zero

That last pair is the point of the suite. It is easy to write a backup script that works when
everything is fine.

## What I learned

- Verifying the copy on the destination, not the source, is what catches a bad USB stick. The
  archive was fine when it was written and corrupt after landing on the other disk, and only a
  checksum on the far side sees that.
- Setting a variable inside `$(command substitution)` does nothing to the parent shell. My error
  counter silently stayed at zero for every failure raised in a subshell, which the test suite
  caught and I would not have.
- `mkdir` is an atomic lock and it works everywhere, unlike `flock`. Checking for a lock file with
  `-f` and then creating it is a race, however unlikely it feels.
- Rotating per tier rather than "keep the newest 20" is what stops a busy week from quietly
  eating your only six month old copy.
- An unmounted second medium has to be an error. If `/mnt/usb-backup` is not mounted, writing
  there succeeds, lands on the root filesystem, and now you have two copies on one disk and a
  green light saying otherwise.
- `set -euo pipefail` and `|| true` in the right places. The job should not abort because one
  source of five is unreadable, but it must not report success either.

## Next

Append only or snapshotted storage on the offsite end, because ransomware that reaches the LAN
reaches the mounted second copy too, and encryption at rest with age so the offsite copy is not
readable by whoever runs that machine.
