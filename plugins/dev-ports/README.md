# Local Ports

A bar button that answers *did I leave a dev server running, and in which
checkout* — and stops it.

The bar shows an anchor. When a dev server is listening it carries a red dot,
the way a chat app marks unread messages: it says *something is open*, not how
many. Hover for the count; click for the list.

```
  ⚓ Local Ports                                           󰑐

  bonsai · concierge-report-full-funnel
  ●  3002   next-server (v15.5.24)                        󰅙
            webapp/  network  pid 2388920
  ○  8797   workerd                                       󰅙
            api-worker/  local  pid 2389076
  ○  9233   workerd                                       󰅙
            api-worker/  local  pid 2389076

  bonsai-harness
   main
  ●  1337   bun                                           󰅙
            projects/search-engine-v5/  network  pid 617436
```

One port per line, grouped by the git checkout the process runs from, in your
theme's own colours: ports in yellow, checkouts in blue, a branch in magenta when
the heading cannot already tell you it, and green only for a port that answers
from the network. A filled dot means reachable from the network; a ring means
this machine only.

**Only dev ports.** A dev port is one held by a process you own, running out of a
git checkout, on a port somebody chose. That leaves out system services (nothing
here can stop them), applications like Steam and Discord (their working directory
is never a checkout), and ephemeral ports the kernel handed out. Earlier versions
kept the last two one click away, under a count. They were never opened.

**How a process is placed in a checkout.** Its working directory, from
`/proc/<pid>/cwd`, handed to `git rev-parse`. Every dev server on the desk this was
built on had its cwd inside a checkout and every application had its cwd in
`$HOME` or an install directory, so the same fact that names the branch also
decides what is a dev port.

**When the dot appears.** The list refreshes every thirty seconds while the panel
is shut and every four while it is open, so a server you start is marked within
half a minute without you going to look.

Keys, while the card is open: `j`/`k` or arrows to move, `enter` to stop, `f` to
force, `r` to refresh, `esc` to close. Nothing is signalled without answering a
question that names the process and its pid, and the cursor starts on **Cancel**.

## Installing

It ships inside hyprpeach, which is one plugin in Omarchy's registry, and is
added from there:

```bash
hyprpeach plugin add dev-ports
```

That links this folder into `~/.config/omarchy/plugins/hyprpeach.dev-ports` and
places it in the right-hand bar section. It is a link rather than a copy, so
`omarchy plugin update` on hyprpeach updates this with it. Take it off with
`hyprpeach plugin remove dev-ports`.

It is a plugin of its own rather than a second widget because Omarchy reads
exactly one `entryPoints.barWidget` out of each manifest and finds third-party
plugins one directory deep, so two bar widgets from one repository means two
plugin folders. `Ports.qml` says this at more length, with the file and version.

## Prior art

**A ports widget for the bar is not a new idea, and this is not the first one.**
At least eleven have been submitted to the Omarchy plugin marketplace since
August 2026, and if you want one that does more than this — Docker containers,
framework fingerprinting, notifications when a dev server dies, SSH tunnel
health — one of them almost certainly already does. None of them is established
(all were at zero or one star when this was written), and none of them is
first-party; Omarchy ships no ports widget of its own.

What this one owes, specifically:

**The command.** `ss -ltnp`, from [iproute2](https://github.com/iproute2/iproute2)
— originated by Alexey Kuznetsov, maintained by Stephen Hemminger — which
replaced `netstat` from [net-tools](https://github.com/ecki/net-tools) (user
interface by Fred Baumgarten) and `lsof` by Victor A. Abell of the Purdue
University Computing Center. Every design decision about *what to read* starts
there, and `ss -ltnp` is what essentially every tool in this list actually runs.

**[portop](https://github.com/padovanl/portop)** by padovanl — an htop-style
ports TUI, and the best-executed thing in this space anywhere. Two ideas taken
from it: naming a well-known port out of `/etc/services`, and attributing a
socket to its systemd unit by reading the cgroup path rather than talking to
D-Bus. Its `k`-then-confirm kill, with an explicit choice of signal, is the shape
of the confirmation here.

**[omarchy-ports](https://github.com/RohitKaushal7/omarchy-ports)** by
RohitKaushal7 — the *reach* axis: that the interesting thing about a listening
port is whether it answers from outside this machine. Its rule that the bar
should only raise an alarm for a network-reachable port is right in principle and
not followed here; `Model.js` says what happened when it was tried.

**[omarchy-ports](https://github.com/rubenmeza/omarchy-ports)** by rubenmeza —
grouping rows by owning process rather than by port number, and refusing to
signal a pid whose identity has changed since the scan.

**[omarchy-port-manager](https://github.com/AdemBenAbdallah/omarchy-port-manager)**
by AdemBenAbdallah and
**[NightsWatch](https://github.com/yenst/NightsWatch)** by yenst — why the stop
action goes through `pidfd_open(2)` and `pidfd_send_signal(2)` instead of
`kill(2)`. A security review of the first forced that fix, and it is the right
one: after a scan, a bare `kill(pid)` is a real time-of-check-to-time-of-use bug.
This is the single most valuable thing on this page.

**[omarchy-ports](https://github.com/okurmustafa/omarchy-ports)** by okurmustafa
— the earliest such plugin we could find (submitted 15 August 2026) — for acting
on the systemd *unit* rather than the pid when a port belongs to a system
service. This widget names the unit but does not act on it.

**[PortKiller](https://github.com/EAspotifi/portkiller)** by EAspotifi, a GNOME
Shell extension — SIGTERM first and SIGKILL only on escalation, and hiding the
noise by default rather than making the reader filter it.

**[waybar-port-status](https://github.com/cyber-drak/waybar-port-status)** by
cyber-drak got there first for Waybar.

Further afield, for the craft rather than the features:
[bandwhich](https://github.com/imsnif/bandwhich) by imsnif (now in passive
maintenance) for the model of cross-referencing sockets against `/proc` to
attribute them to processes; [sniffnet](https://github.com/GyulyVGC/sniffnet) by
GyulyVGC for service fingerprinting and a glanceable thumbnail mode;
[impala](https://github.com/pythops/impala) by pythops for the shape of a small
tool that owns one domain completely; and
[procs](https://github.com/dalance/procs) by dalance for documenting the
constraint every unprivileged tool here lives under — procfs only reveals
listening sockets for processes the current user owns.

Not borrowed from, and worth knowing about if this is not enough:
[Portal](https://github.com/g3ortega/omarchy-portal) (g3ortega) fingerprints the
framework behind a port, [Portside](https://github.com/Saikomantisu/omarchy-portside)
(Saikomantisu) notifies when a dev server starts, dies, or becomes reachable, and
[lsport](https://github.com/subediparas5/lsport) (subediparas5) adds a k9s-style
regex filter and monitoring over SSH.
