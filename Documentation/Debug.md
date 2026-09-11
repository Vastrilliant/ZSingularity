# DEBUG

The Debug section is a live viewer for the process's own `stdout`/`stderr` — the same stream every `NSLog` call (including the tweak's own logging, done through the `ZLog` macro) writes to. It doesn't produce log lines itself; it captures and displays ones that already exist.

This workaround is necessary to avoid corrupt logs when reading NSLogs directly on iOS18+

## Syslog

Capture works by redirecting the process's `stdout` and `stderr` file descriptors into a pipe, so it can read every line written to either one as it happens. The original descriptors are preserved and every line is written back out to them immediately after being read, so nothing about the process's normal logging behavior changes just because the viewer happens to be open — anything else reading `stdout`/`stderr` (a device console, a debugger) still sees the same output it always would.

## Debug mode

Holding down **Syslog** for about a second, switches it into **Debug** mode. The log view narrows to only lines that contain this tweak's own log tag — filtering out the game's own logging and everything else sharing the process's `stdout`/`stderr`, so the view only shows messages this tweak itself produced.

## Blacklisted keywords

The **Blacklist keywords** field lets specific noisy lines be silenced entirely rather than just scrolled past. Enter one or more comma-separated terms and press return to add them — each is matched as a case-insensitive substring against every log line.

A blacklisted term:

- Prevents any future matching line from ever entering the buffer.
 
- Immediately removes any already-buffered lines that match, as soon as it's added — it isn't limited to filtering new output going forward.
 
- Persists across relaunches, along with the tweak's other settings, until removed.