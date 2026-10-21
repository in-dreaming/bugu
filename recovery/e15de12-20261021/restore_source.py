#!/usr/bin/env python3
"""Offline, hash-checked reconstruction. No download, build, test, or push."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import zipfile


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def verify(path, expected, size=None):
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f'Missing or unsafe input: {path.name}')
    if size is not None and path.stat().st_size != size:
        raise RuntimeError(f'Size mismatch: {path.name}')
    if sha256(path) != expected:
        raise RuntimeError(f'SHA256 mismatch: {path.name}')


def safe_name(name):
    p = Path(name)
    if p.is_absolute() or '..' in p.parts or '.git' in p.parts or '\n' in name or '\0' in name:
        raise RuntimeError(f'Unsafe archive path: {name!r}')
    return p


def atomic_json(path, data):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).with_name('recovery-manifest.json'))
    args = parser.parse_args()
    inputs, repo = args.inputs.resolve(), args.repo.resolve()
    manifest = json.loads(args.manifest.read_text())
    digest = sha256(args.manifest)
    state_dir = repo.with_name(repo.name + '.recovery')
    marker = state_dir / 'state.json'
    if marker.exists():
        state = json.loads(marker.read_text())
        if state.get('manifest_sha256') != digest:
            raise RuntimeError('Recovery manifest differs from existing state; refusing to continue')
    else:
        if repo.exists() and any(repo.iterdir()):
            raise RuntimeError('Existing nonempty repository has no matching recovery marker')
        state_dir.mkdir(parents=True, exist_ok=True)
        state = {'schema': 1, 'manifest_sha256': digest, 'complete': False, 'stages': []}
        atomic_json(marker, state)
    repo.mkdir(parents=True, exist_ok=True)

    def git(*argv, data=None):
        p = subprocess.run(['git', '--no-optional-locks', '-c', 'core.autocrlf=false',
                            '-c', 'core.filemode=true', *argv], cwd=repo, input=data,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode:
            raise RuntimeError(f'git {argv}: {p.stderr.decode(errors="replace")}')
        return p.stdout

    if not (repo / '.git').exists():
        git('init', '--initial-branch=recovery/e15de12')
    elif not (repo / '.git').is_dir():
        raise RuntimeError('Linked worktrees or external git directories are not accepted')

    if state['complete']:
        if git('rev-parse', 'HEAD^{tree}').decode().strip() != manifest['final_tree']:
            raise RuntimeError('Existing HEAD differs from recovered checkpoint; refusing to overwrite')
        if git('status', '--porcelain=v1', '--untracked-files=all'):
            raise RuntimeError('Existing repository has changes; refusing to overwrite')
        print('Already recovered; exact final tree and clean worktree verified:', repo)
        return

    # Only a marked incomplete recovery may be resumed. Never run reset/clean.
    roles = {}
    for item in manifest['inputs']:
        source = inputs / item['name']
        verify(source, item['sha256'], item['bytes'])
        target = state_dir / item['role']
        target.mkdir(exist_ok=True)
        if source.name.endswith('.zip'):
            with zipfile.ZipFile(source) as archive:
                for info in archive.infolist():
                    safe_name(info.filename)
                    if (info.external_attr >> 16) & 0o170000 == 0o120000:
                        raise RuntimeError('Symlink in patch archive is not allowed')
                archive.extractall(target)
            for line in (target / 'SHA256SUMS').read_text().splitlines():
                checksum, name = line.split('  ', 1)
                verify(target / safe_name(name), checksum)
        else:
            with tarfile.open(source) as archive:
                for member in archive.getmembers():
                    safe_name(member.name)
                    if not (member.isfile() or member.isdir()):
                        raise RuntimeError('Only regular files and directories are accepted')
                archive.extractall(target, filter='data')
            for item_hash in json.loads((target / 'manifest.json').read_text())['entries']:
                verify(target / safe_name(item_hash['path']), item_hash['sha256'], item_hash['bytes'])
        roles[item['role']] = target

    source_tar = roles['source_archive'] / manifest['archive']['name']
    verify(source_tar, manifest['archive']['sha256'], manifest['archive']['bytes'])
    patch_paths = []
    for stage in manifest['stages']:
        path = (inputs if stage['source'] == 'inputs' else roles[stage['source']]) / stage['patch']
        verify(path, stage['sha256'], stage.get('bytes'))
        patch_paths.append(path)

    if not (repo / '.git/index').exists():
        unpacked = state_dir / 'archive-source'
        unpacked.mkdir(exist_ok=True)
        members = []
        seen = set()
        with tarfile.open(source_tar) as archive:
            if archive.pax_headers.get('comment') != manifest['archive']['commit']:
                raise RuntimeError('Source archive provenance does not match')
            for member in archive.getmembers():
                safe_name(member.name)
                if member.isdir():
                    continue
                if not member.isfile() or member.name in seen:
                    raise RuntimeError('Unexpected file type or duplicate source path')
                seen.add(member.name)
                members.append(member)
            archive.extractall(unpacked, filter='data')
        paths = [(unpacked / member.name).resolve() for member in members]
        oids = git('hash-object', '--no-filters', '-w', '--stdin-paths',
                   data=('\n'.join(str(p) for p in paths) + '\n').encode()).decode().splitlines()
        if len(oids) != len(members):
            raise RuntimeError('Unexpected blob hash count')
        lines = []
        for member, oid in zip(members, oids):
            mode = '100755' if member.mode & 0o111 else '100644'
            lines.append(f'{mode} {oid}\t{member.name}\0'.encode())
        archived_pins = (roles['source_archive'] / 'pinned-gitlinks.txt').read_text()
        declared_pins = ''.join(f"160000 commit {item['pin']}\t{item['path']}\n" for item in manifest['gitlinks'])
        if archived_pins != declared_pins:
            raise RuntimeError('Archive gitlinks do not match manifest')
        for item in manifest['gitlinks']:
            lines.append(f"160000 {item['pin']}\t{item['path']}\0".encode())
        git('update-index', '-z', '--index-info', data=b''.join(lines))

    known = [manifest['archive']['tree']] + [stage['tree'] for stage in manifest['stages']]
    tree = git('write-tree').decode().strip()
    if tree not in known:
        raise RuntimeError('Index does not match any exact known recovery stage')
    start = known.index(tree)
    if start > len(state['stages']):
        # A prior process may have completed atomic Git index write before logging.
        state['stages'] = [{'stage': 'cb2c224' if i == 0 else manifest['stages'][i-1]['label'],
                            'tree': expected, 'verified': True} for i, expected in enumerate(known[:start+1])]
    print('Verified current stage tree:', tree, flush=True)
    for i in range(start, len(manifest['stages'])):
        stage, patch = manifest['stages'][i], patch_paths[i]
        flags = ['--cached'] + (['--reverse'] if stage['reverse'] else [])
        git('apply', *flags, '--check', str(patch))
        git('apply', *flags, str(patch))
        tree = git('write-tree').decode().strip()
        if tree != stage['tree']:
            raise RuntimeError(f"Tree mismatch after {stage['label']}: {tree}")
        state['stages'].append({'stage': stage['label'], 'tree': tree, 'verified': True})
        atomic_json(marker, state)
        print('Verified', stage['label'], tree, flush=True)

    if tree != manifest['final_tree']:
        raise RuntimeError('Final tree mismatch')
    indexed = []
    for line in git('ls-files', '--stage', '-z').split(b'\0'):
        if not line:
            continue
        info, raw_path = line.split(b'\t', 1)
        mode, oid, stage = info.decode().split()
        if stage != '0':
            raise RuntimeError('Unmerged index')
        indexed.append((mode, oid, raw_path.decode()))
    # If final checkout was interrupted, existing files must already match.
    allowed = {path for mode, oid, path in indexed}
    gitlink_paths = {path for mode, oid, path in indexed if mode == '160000'}
    for current in repo.rglob('*'):
        relative = current.relative_to(repo)
        if relative.parts[0] == '.git' or any(str(relative) == p or str(relative).startswith(p + '/') for p in gitlink_paths):
            continue
        if current.is_file() or current.is_symlink():
            if str(relative) not in allowed:
                raise RuntimeError(f'Unexpected worktree file: {relative}')
    for mode, oid, relative in indexed:
        path = repo / relative
        if mode == '160000':
            continue
        if path.exists() or path.is_symlink():
            if path.is_symlink() or not path.is_file():
                raise RuntimeError(f'Unexpected worktree type: {relative}')
            data = path.read_bytes()
            actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            if actual != oid or bool(path.stat().st_mode & 0o111) != (mode == '100755'):
                raise RuntimeError(f'Existing worktree file differs: {relative}')
    message = ('Synthetic source recovery checkpoint for ' + manifest['original_source_commit'] + '\n\n'
               'Exact source tree reconstructed from verified archive and patches.\n'
               'Original commit object and history are not restored.\n'
               'No build or test qualification is implied.\n')
    commit = git('-c', 'user.name=Source Recovery', '-c', 'user.email=recovery@localhost',
                 'commit-tree', tree, data=message.encode()).decode().strip()
    git('update-ref', 'refs/heads/recovery/e15de12', commit)
    git('checkout-index', '--all', '--force')
    git('update-index', '--refresh')
    if git('status', '--porcelain=v1', '--untracked-files=all'):
        raise RuntimeError('Final worktree is not clean')
    if git('rev-parse', 'HEAD^{tree}').decode().strip() != manifest['final_tree']:
        raise RuntimeError('Final HEAD tree mismatch')
    state.update({'complete': True, 'final_tree': tree, 'synthetic_commit': commit,
                  'original_history_restored': False, 'builds_or_tests_run': False})
    atomic_json(marker, state)
    atomic_json(repo / '.git/recovery-provenance.json', state)
    print('Recovered source repository:', repo)
    print('Synthetic recovery commit:', commit)


if __name__ == '__main__':
    main()
