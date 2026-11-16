# Headless character configuration

`forever_client.py up`, `smoke` and `proof` read the launch record at
`$XDG_CONFIG_HOME/forever-client/env.json` (or `~/.config/forever-client/env.json`).
The record must contain the runner fields captured by `capture-env` and an owner-approved
character block:

```json
"character": {
  "name": "Barry",
  "guid": "Player-...",
  "require_resting": true
}
```

The name and GUID prevent a proof from entering a different character. `require_resting`
requires the client to report the character resting before the headless addon emits its
world-ready marker. A missing or malformed block stops before the launcher starts. The
headless addon copy and its generated Lua configuration live only under the session state
directory and are removed during normal or stale-session cleanup.
# Hyprland lease

deskpilot is a Hyprland plugin, so it cannot see or click a window inside the
headless gamescope session. `lease --hyprland` moves the client into a private nested
Hyprland for one agent and back again afterwards:

```sh
python3 tools/headless/forever_client.py lease --hyprland [--ttl S] [--label TEXT]
```

Run it from a shell in your Hyprland session: it needs `WAYLAND_DISPLAY` to find the
parent compositor. Without `--hyprland`, `lease` holds the gamescope client as before.

How it works:

1. The lease writes a request and waits. `serve` (started for it when no session runs)
   takes the job lock once the job in flight ends, logs the character out of gamescope,
   and starts a nested Hyprland whose window opens on the hidden
   `special:forever-client` workspace of your session. Nothing appears on your screen.
2. `serve` launches Battle.net and the client on the nested compositor's XWayland, so
   Wow.exe is a plain XWayland client there, and waits for the world as it does under
   gamescope.
3. The lease prints one JSON line and exits:

   ```json
   {"token": "...", "HYPRLAND_INSTANCE_SIGNATURE": "...", "WAYLAND_DISPLAY": "wayland-2",
    "DISPLAY": ":3", "window": "0x55...", "title": "World of Warcraft", "expires": 1794843000.0}
   ```

4. Drive the client with deskpilot pointed at the nested compositor only. Load the plugin
   there, never in your own session:

   ```sh
   export HYPRLAND_INSTANCE_SIGNATURE=<signature> WAYLAND_DISPLAY=<wayland>
   deskpilot plugin load
   deskpilot shot <window>
   ```

   The `forever_client.py` verbs (`shot`, `click`, `slash` and the rest) also work
   inside the lease with `FOREVER_CLIENT_JOB=<token>`.
5. `forever_client.py release TOKEN` ends the lease. `serve` logs out, stops the nested
   Hyprland, relaunches the client under gamescope, and releases the job lock once it is
   in the world there. `release` returns at that point.

`serve` holds the job lock for the whole span, so jobs that queue meanwhile (proofs,
smokes) wait and then run on the restored gamescope session. The return to gamescope
also runs when the lease expires (`--ttl`, 15 minutes by default, 30 at most, counted
from the moment the lease is granted), when the client or the nested Hyprland exits,
and when the lease is cancelled before it is granted (stopping the waiting
`lease --hyprland` process). If the return itself fails, `serve` tears the session
down completely, so the next job starts a fresh gamescope session. `down` during a
lease ends the session without the relaunch.

Each lease costs two logins, so use it only for checks that need deskpilot's input path,
such as cjber/deskpilot#95. The nested compositor code in `nested_hyprland.py` is adapted
from cjber/deskpilot's `scripts/nested.py`; no deskpilot checkout is needed at runtime.
