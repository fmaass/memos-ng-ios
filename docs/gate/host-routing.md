# Gate host routing and the run lock

Moved verbatim from CLAUDE.md § The gate is the only build authority on 2026-10-16.

Inside the pfadfinder-lane container the same gate takes the jupiter-local estate lock ITSELF —
`MAC_GATE_ESTATE_LOCK` names the lock file that is the estate-wide exclusion for Mac gates (this
script's own lock is per branch and serialises nothing across repos), and the run then stamps
`lock_requested`/`lock_acquired` into its log and its row in `worktrees/gate-runs.tsv`. Never wrap
that command in an outer `flock` on the same file as well: the gate would wait on itself forever.
It names the build host by the ssh alias `merkur`, the only name the container's key is bound to
(`merkur.local` does not authenticate there):

    `env MAC_GATE_ESTATE_LOCK=/home/fabian/projects/worktrees/.wp13-gate.lock MAC_GATE_HOST=merkur bin/mac-gate.sh`

**The gate can pick the build host itself (MEMNG-824).** `MAC_GATE_HOST=auto` with the per-host lock
map `MAC_GATE_ESTATE_LOCKS=merkur=/home/fabian/projects/worktrees/.wp13-gate.lock,mars=/home/fabian/projects/worktrees/.mars-gate.lock`
(preference order, names limited to the mount guard's profiles) tries each host's lock with
`flock -n` in map order and takes the first that is free AND answers `ssh -o BatchMode=yes -o
ConnectTimeout=10 <host> true` under `timeout 30`. With every host busy it probes the busy ones and
polls the answering ones (MEMNG-1040): every `MAC_GATE_HOST_POLL` seconds (default 15) one round of
`flock -n` over all of them, and the first lock that is free is taken. It never blocks on one
host's lock — that waited as long as the holder needed while the other host sat idle, and held two
lane gates on merkur for an hour with mars free. Within a round the host named by
`<artifacts>/lane-host` (written by every run that reaches the remote step: `<host> <branch> <UTC>
<run token>`; read only for this branch and under 24 h old) is tried first, then map order, so the
warm lane only breaks a tie between hosts free at the same round; the route's reason ends `->
waited on <h> (warm lane)` or `(first free)`, and stderr announces the wait once (`every build host
is busy; polling …`). A host whose lock is taken but which then stops answering is let go and
dropped from the set, and the round goes on. No answering host, `auto` without the map, or a name the
gate does not know refuses with exit 15 before any lock. The choice is one `route       :
host=<h> reason=<…> worktree_wait=<s>s pid=<n> token=<t>` line in the run log, `host=<name>` sits
on `mac-gate SUMMARY:` and `MAC_GATE_QUICK:` just before `locallint=`, and the run ledger's rows
carry it as a 13th field (`host`; the 13-name header is written only into a new or empty ledger,
so an older ledger keeps its 12-name header above mixed 12/13-field rows). An explicit host with
`MAC_GATE_ESTATE_LOCK` behaves as before; an explicit host with only the map takes its own entry.
Every run that builds or tests — explicit or `auto` — also holds the worktree's run lock,
`<artifacts>/.run.lock` (a kernel `flock` on descriptor 7, taken after the local lint and before the
estate lock, released only when the run's process exits), so two runs of one worktree never
overlap on two hosts over one artifacts directory; it carries one informational `pid= token=
host=` line and needs no reclaim. Every line that closes descriptor 9 for a child or a subshell
closes 7 too, the router's own `exec 9>&-` lines excepted; `tests/gate/host-routing-test.sh`, a
named selftest, holds all of it. `bin/testflight-cut.sh` does not take `auto`: keep its explicit
host and lock — its `--resolve-build` mode included, which runs `fastlane prove_unused` from the
authorised commit's build + 1 until one number is proven unused and prints `RESOLVED-BUILD
version=<v> build=<n> probes=<k> seconds=<s>` (exit 21 when a number is not proven either way, 22
after eight spent in a row), archiving, claiming and uploading nothing. `bin/bump-build.sh --build
<n> --notes-file <path>` then writes that number into both build key lines and its notes section in
one commit on a work branch; its suite, `tests/gate/bump-build-test.sh`, is a named selftest too.
