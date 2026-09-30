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
3. If the service started less than 10 minutes ago, or its start time can't
   be read, leave it alone. A game that is still starting up is never cut
   off.
4. Otherwise, stop the service.

Every run appends one JSON line to
`C:\ProgramData\ElytraGuard\elytraguard.log`, which rotates at 1 MB.

## Install

Requires Windows 10 or 11 and admin rights. It uses the built-in Windows
PowerShell 5.1.

```powershell
# In an elevated PowerShell, from the downloaded folder:
Get-ChildItem *.ps1 | Unblock-File     # if you downloaded a zip
.\install.ps1                          # or: .\install.ps1 -IntervalMinutes 5 -GraceMinutes 10
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

Neither needs admin rights; both run under Windows PowerShell 5.1 and
PowerShell 7.

- `tests\status.tests.ps1` checks the status output against sample logs.
- `tests\guard.tests.ps1` runs the guard with `-DryRun` against real
  services and a stand-in game process, so nothing is ever stopped.

## Uninstall

```powershell
.\uninstall.ps1               # keeps the log
.\uninstall.ps1 -RemoveLogs
```

## License

MIT
