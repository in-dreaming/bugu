# Exact source recovery and minimal Linux environment

This recipe reconstructs the source tree corresponding to original source
commit `e15de1243d23fa67449674ab75fcebe735e9840d`. It does not recover the
original commit object/history and does not claim a passing build or test.

## Inputs and provenance

Supply the three named checkpoint archives listed in `recovery-manifest.json`
through an authorized file-transfer route. The recipe contains no private
download links, account identifiers, or credentials. These archives are not
redistributed here.

Also place the three patch files identified by `source: inputs` in that same
input directory. Their repository paths and immutable delivery commit are in
the manifest. Retrieve them from that exact commit, not the moving branch tip.
Every input must pass the published size and SHA-256 checks.

The source chain is cb2c224, reverse to 4cdbbf5, then 6f3fb3a, 6c154b8,
94f5907, and e15de12. Every intermediate Git tree is checked. Gitlinks and
executable modes are retained. Internal archive manifests are checked too.

## Recover source, without network or tests

Requirements: Python 3.12 or later and Git. Use a new repository directory:

```sh
python3 restore_source.py --inputs /path/to/verified-inputs --repo /path/to/new-repo
```

The script performs no network access, dependency installation, build, test,
push, or global Git configuration changes. A local synthetic commit is created
with command-scoped `user.name=Source Recovery` and
`user.email=recovery@localhost`. This identity applies only to the recovery
commit invocation; it is not a global identity change or a claim about the
original author.

A sibling `<repository-name>.recovery` directory holds recovery state. Keep it
with the repository if resuming this operation. An already completed recovery
is accepted only when its final HEAD tree and worktree are unchanged. Changed
repositories are rejected rather than reset or cleaned. Do not rerun recovery
over subsequent development work; use a fresh destination instead.

Incomplete marked recovery directories can resume from exact known index
trees. Existing worktree files are checked against the final index before
checkout; differing contents are rejected. The initial recovery and clean
no-op rerun have been executed successfully. Interrupted-resume and dirty-target
failure paths have not been separately exercised. See
`restoration-validation.json` for precise execution scope and evidence hashes.

## Optional minimal environment recovery

This is a separate, explicit network operation:

```sh
python3 restore_environment.py --repo /path/to/new-repo --tools /path/to/local-tools --verify-version
```

It downloads the official Zig 0.16.0 Linux x86_64 archive, checks the archive
and binary SHA-256, and optionally executes only `zig version`. Installation
stays under the chosen local tools directory; system settings and credentials
are not changed.

It restores the exact miniaudio, Opus, Ogg, and FreeType pins plus only the four
required Unicode data files and Unicode LICENSE. Other dependency licenses are
retained in their source checkouts. Existing changed or different dependency
checkouts are rejected. Source access failure stops the operation; the script
does not substitute mirrors, latest branches, or different revisions.

FreeType and Unicode inputs are needed by the existing global build-graph
registration even for the focused audio checks. GPU and Noto CJK are deliberately
not restored. This minimal environment is not a general UI/visualizer setup.
Do not set `sme-gpu-source` or assume a default install/full test suite is covered.

The manifest lists four focused build steps. Neither script runs them. Builds
and tests require separate execution and reporting; source and dependency
integrity do not imply correctness, replay qualification, or Windows acceptance.

## Persistence and later work

Local recovery state and caches alone do not protect against executor loss.
Use authorized Git checkpoints for each bounded change, preserving source-tree
identity, patch hashes, and honest validation status. Keep replay evidence and
raw runtime logs separate from claims about the code. Do not describe an
unexecuted or interrupted check as passing.
