# ElytraGuard

Stops the **Elytra anti-cheat** service when **WARDOGS** is not running.

In September 2026 WARDOGS replaced Easy Anti-Cheat with Elytra (by VAIIYA).
Elytra installs a Windows service, `Elytra.Service`, that runs as
LocalSystem. The game starts the service when it launches, but the service
can keep running after the game has closed. ElytraGuard is a small scheduled
task that stops the service again once the game is gone, so the anti-cheat
only runs while you play.

It does **not** block, modify or uninstall Elytra, and it never touches game
files. The next time you start WARDOGS, the game starts the service again as
usual.

> Not affiliated with Bulkhead, Team17, VAIIYA or Embark. Use at your own
> risk. ElytraGuard only acts while the game is closed, but read the game's
> terms if you are unsure.

## How it works

`elytraguard.ps1` runs as SYSTEM at startup and every 5 minutes. On each run:

1. If Elytra isn't running, do nothing.
2. If any process from the WARDOGS install folder is running, or a process
   with a known game name (`WardogsLauncher-Shipping`,
   `WardogsClient-Win64-Shipping`), leave Elytra alone. The install folder is
   found through your Steam libraries, so this still works if a game update
   renames its executables.

   The run then stays and waits for the game to close, without using any
   CPU. Once the game has been closed for 45 seconds it carries on with the
   steps below, so Elytra stops about a minute after you quit instead of at
   the next run. The 45 seconds cover the switch from launcher to game
   client.
3. If the service started less than 10 minutes ago, or its start time can't
   be read, leave it alone. A game that is still starting up is never cut
   off. This step is skipped after waiting for the game, since the game has
   then clearly come and gone.
4. Otherwise, stop the service.

Every run appends one JSON line to
`C:\ProgramData\ElytraGuard\elytraguard.log`, which rotates at 1 MB. A run
that is waiting for the game adds a `game_running` line every 5 minutes, just
as the scheduled runs it stands in for would.

## Watching Elytra for changes

A game update can change what Elytra installs. On its first run the guard
records how Elytra is set up, and every run after that compares against the
record:

- the service: program, start type, account, type, dependencies,
  permissions and recovery actions;
- the program files (`.exe`, `.dll`, `.sys`) in Elytra's folder, with their
  SHA-256 hash and signing certificate: its name, thumbprint and chain. A
  file only counts as signed if Windows finds the signature valid, meaning
  intact and chained to a root it trusts. The `Content` folder holds data
  packages that change all the time and is left out;
- any other service, driver or scheduled task named after Elytra or VAIIYA,
  or running a program from Elytra's folder.

An ordinary update, where program files change but are validly signed with
a certificate already in the record, is logged as `"footprint": "updated"`
and the record moves along. Certificates are matched by thumbprint, not by
name, so another certificate issued to the same company name is a warning
too. So is a changed service setting, an unsigned file, any driver file, a
new related service, driver or task, or Elytra's folder left behind without
its service.
The warning appears in the log and in `status.ps1` on every run until you
have looked at it and accept it in an elevated PowerShell:

```powershell
& "$env:ProgramFiles\ElytraGuard\elytraguard.ps1" -AcceptElytraChanges
```

The record is `C:\ProgramData\ElytraGuard\elytra-baseline.json`. Like the
log, only SYSTEM and Administrators can change it, so a program running
without admin rights can't rewrite it to hide a change. Each time the guard
saves it, it also stores its SHA-256 in the registry, under
`HKLM\SOFTWARE\ElytraGuard`. A record that has been deleted, edited, or has
no matching hash is a warning (`"footprint": "unverified"`), never a quiet
fresh start, until you accept Elytra's current setup as above. The very
first record trusts Elytra as it is at that moment, so install ElytraGuard
on a PC you trust. ElytraGuard itself never changes Elytra's settings or
files; it only watches them.

Not covered: a driver or service with an unrelated name, installed somewhere
else. The `footprint` field of each log line is `recorded`, `same`,
`updated`, `changed`, `unverified`, `accepted` or `error`.

## Install

Requires Windows 10 or 11 and admin rights. It uses the built-in Windows
PowerShell 5.1.

The easiest way is `elytraguard-setup.exe` from the
[latest release](https://github.com/superhelten/elytraguard/releases/latest).
Run it and accept the admin prompt. The setup program isn't code-signed, so
SmartScreen may say "Windows protected your PC"; choose *More info*, then
*Run anyway*. Setup only unpacks the scripts and runs the same `install.ps1`
described below, so both ways end in the same state. It also adds ElytraGuard
to *Settings > Apps > Installed apps*, where you can uninstall it. It is
built from `installer\elytraguard.iss` with [Inno Setup](https://jrsoftware.org/isinfo.php)
6 by `installer\build.ps1`.

To install from the zip instead:

```powershell
# In PowerShell. Without admin rights it asks for them (UAC) and carries on
# in a new window. Use the folder the zip was extracted to; Windows names a
# second download "elytraguard (1)".
cd "$HOME\Downloads\elytraguard"
powershell -ExecutionPolicy Bypass -File .\install.ps1
# Options: -IntervalMinutes 5 -GraceMinutes 10
```

The installer:

- copies the guard and `status.ps1` to `C:\Program Files\ElytraGuard`.
  Normal users can't write there, which matters because the task runs as
  SYSTEM.
- creates the log folder. Users can read it, but only SYSTEM and
  Administrators can write to it.
- registers the `ElytraGuard` task.

## Is it working?

```powershell
& "$env:ProgramFiles\ElytraGuard\status.ps1"
```

This prints a verdict, whether Elytra is running right now, and what the
guard did recently, with identical runs merged into one line:

```
ElytraGuard: OK
  Elytra anti-cheat is stopped right now.
  Last check 1 min ago (checks run every 5 min).

What happened:
  13:41-14:31  WARDOGS open, Elytra left running (11 checks)
  14:36        WARDOGS closed, Elytra stopped by ElytraGuard
  14:41-14:46  Nothing to do, Elytra already stopped (2 checks)

Scheduled task details need an admin prompt; that is normal.
```

It shows `NOT OK` and exits with code 1 for:

- a task that is disabled or has stopped running;
- a missing or empty log;
- warnings or errors in the log;
- Elytra still running without the game after several runs.

Run it elevated to see the task details too.

The `result` field in the log is one of:

| result | meaning |
|---|---|
| `idle` | Elytra not running, nothing to do |
| `game_running` | the game is running, Elytra left alone |
| `grace` | Elytra started recently, left alone for now |
| `stopped` | Elytra stopped |
| `would_stop` | dry run (`-DryRun`), nothing stopped |
| `no_service` | Elytra not installed |
| `accepted` | an admin ran `-AcceptElytraChanges` |
| `error` | something failed, see `message` |

A `warn` line means the WARDOGS install folder wasn't found. The guard then
falls back to the known process names.

### Push alerts (optional)

The log is JSON lines, so any log shipper can pick it up. With Loki and
Grafana, three rules cover the ways the guard can fail silently:

```logql
# Guard not running (task disabled/deleted): alert when this is < 1, and on "no data"
sum(count_over_time({job="elytraguard"} [15m]))

# Elytra running without the game on 4+ runs in 20 min: alert when > 3
sum(count_over_time({job="elytraguard"} | json | service_state="Running" | game_running="false" [20m]))

# Guard reported a problem: alert when > 0
sum(count_over_time({job="elytraguard", level=~"warn|error"} [10m]))
```

## Tests

None needs admin rights; all run under Windows PowerShell 5.1 and
PowerShell 7.

- `tests\status.tests.ps1` checks the status output against sample logs.
- `tests\guard.tests.ps1` runs the guard with `-DryRun` against real
  services and a stand-in game process, so nothing is ever stopped. It
  refuses to run while WARDOGS is open.
- `tests\footprint.tests.ps1` checks which changes to Elytra's setup count
  as an update and which as a warning.

## Uninstall

If you used the setup program, uninstall ElytraGuard from *Settings > Apps >
Installed apps*. It asks whether to delete the log and the record of
Elytra's setup as well; a silent uninstall keeps them. Otherwise, from the
unzipped folder in PowerShell (it asks for admin rights the same way):

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1               # keeps the log
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveLogs   # also removes the record of Elytra's setup and its hash
```

## License

MIT
