# git-sync

Keeps local git clones fresh by fetching and fast-forwarding only when safe; anything needing judgment is left to the user.

## Language

**Run**:
One invocation of `git-sync sync`, covering one repo or every registered repo.

**Job run**:
A run started by the agent on its schedule. Only job runs notify.
_Avoid_: scheduled sync, background run

**Manual run**:
A run started by the user from a shell.

**Blocker**:
A condition in a repo that stops git-sync from bringing it up to date and needs the user's judgment.
_Avoid_: error, failure

**Offline check**:
The test, made before a run touches any repo, of whether the machine has a default network route.
_Avoid_: connectivity probe, reachability check

**Offline skip**:
A run that failed the offline check and left every repo and its status untouched.
_Avoid_: skipped run, offline run

**Offline streak**:
The consecutive offline skips since the last run that actually synced.
