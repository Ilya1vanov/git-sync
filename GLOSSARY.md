# git-sync

Keeps local git clones fresh by fetching and fast-forwarding only when safe; anything needing judgment is left to the user.

## Language

**Run**:
One invocation of `git-sync sync`, covering one repo or every registered repo.

**Sync list**:
The repos a run with `--all` covers. _Install_ is the verb for adding a repo to it.
_Avoid_: register

**Watched root**:
A folder whose depth-1 repos are added to the sync list automatically at each run with `--all`.

**Exclusion**:
A repo under a watched root that the user removed and that git-sync must not add back.

**Job run**:
A run started by the agent on its schedule. Only job runs notify.
_Avoid_: scheduled sync, background run

**Manual run**:
A run started by the user from a shell.

**Blocker**:
A condition in a repo that stops git-sync from bringing it up to date and needs the user's judgment.
_Avoid_: error, failure

**Fetch timeout**:
The longest one fetch from one remote may run before git-sync cuts it off. A cut-off fetch is a blocker for that remote, distinct from a fetch the remote rejected.
_Avoid_: watchdog (the mechanism, not the concept), hang

**Offline check**:
The test, made before a run touches any repo, of whether the machine has a default network route.
_Avoid_: connectivity probe, reachability check

**Offline skip**:
A run that failed the offline check and left every repo and its status untouched.
_Avoid_: skipped run, offline run

**Offline streak**:
The consecutive offline skips since the last run that actually synced.

**Unreachable host**:
A host that failed a connection-class fetch earlier in the same run. Nothing about it is remembered after the run.
_Avoid_: circuit breaker, backoff, dead host

**Host skip**:
A remote that was not fetched because its host is unreachable. It is a note on the repo, not a blocker, and is distinct from an offline skip, which covers a whole run.
_Avoid_: circuit breaker, backoff
