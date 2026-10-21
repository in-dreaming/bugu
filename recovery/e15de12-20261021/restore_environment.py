#!/usr/bin/env python3
"""Explicit network recovery of the pinned minimal Linux environment; no tests."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(argv, cwd=None, data=None, check=True):
    p = subprocess.run(argv, cwd=cwd, input=data, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=240)
    if check and p.returncode:
        raise RuntimeError(f'{argv}: {p.stderr}')
    return p


def verify_toolchain(archive, tools, directory_name):
    """Compare installed bytes, executable bits, directories and link targets."""
    files = 0
    with tarfile.open(archive) as tar:
        for member in tar:
            relative = Path(member.name)
            if relative.is_absolute() or '..' in relative.parts or relative.parts[0] != directory_name:
                raise RuntimeError('Unsafe toolchain archive path')
            target = tools / relative
            if member.isdir():
                matches = target.is_dir() and not target.is_symlink()
            elif member.issym():
                matches = target.is_symlink() and str(target.readlink()) == member.linkname
            elif member.isfile():
                matches = target.is_file() and not target.is_symlink()
                if matches:
                    matches = (target.stat().st_size == member.size and
                               target.stat().st_mode & 0o111 == member.mode & 0o111)
                if matches:
                    with tar.extractfile(member) as expected, target.open('rb') as actual:
                        while block := expected.read(1024 * 1024):
                            if block != actual.read(len(block)):
                                matches = False
                                break
                files += 1
            else:
                raise RuntimeError('Unexpected toolchain archive member type')
            if not matches:
                raise RuntimeError('Installed toolchain differs from verified archive: ' + str(relative))
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).with_name('recovery-manifest.json'))
    parser.add_argument('--verify-version', action='store_true', help='Also execute the verified Zig binary with version only')
    args = parser.parse_args()
    repo, tools = args.repo.resolve(), args.tools.resolve()
    manifest = json.loads(args.manifest.read_text())
    if not (repo / '.git').is_dir():
        raise RuntimeError('Expected a recovered Git repository')
    tools.mkdir(parents=True, exist_ok=True)
    zig = manifest['zig']
    name = Path(zig['url']).name
    archive = tools / name
    binary = tools / ('zig-' + zig['platform'] + '-' + zig['version']) / 'zig'
    if not archive.exists():
        partial = tools / (name + '.part')
        # Partial transfers are never reused as validated archives.
        with urllib.request.urlopen(zig['url'], timeout=180) as response, partial.open('wb') as stream:
            while block := response.read(1024 * 1024):
                stream.write(block)
        if partial.stat().st_size != zig['bytes'] or digest(partial) != zig['sha256']:
            raise RuntimeError('Official Zig archive checksum mismatch; leaving partial file for inspection')
        partial.replace(archive)
    if archive.stat().st_size != zig['bytes'] or digest(archive) != zig['sha256']:
        raise RuntimeError('Existing Zig archive does not match; refusing to replace')
    tool_directory = binary.parent
    tool_marker = tools / (tool_directory.name + '.recovery.json')
    if tool_directory.exists() and not tool_marker.exists():
        raise RuntimeError('Unmarked existing toolchain directory; refusing to overwrite')
    if not tool_marker.exists():
        tool_marker.write_text(json.dumps({'archive_sha256': zig['sha256'], 'complete': False}) + '\n')
    marker_data = json.loads(tool_marker.read_text())
    if marker_data['archive_sha256'] != zig['sha256']:
        raise RuntimeError('Existing toolchain marker does not match')
    if not marker_data['complete']:
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                path = Path(member.name)
                if path.is_absolute() or '..' in path.parts or path.parts[0] != tool_directory.name:
                    raise RuntimeError('Unsafe toolchain archive path')
                if not (member.isfile() or member.isdir() or member.issym()):
                    raise RuntimeError('Unexpected toolchain archive member type')
            tar.extractall(tools, filter='data')
    verified_files = verify_toolchain(archive, tools, tool_directory.name)
    if not binary.is_file() or digest(binary) != zig['binary_sha256']:
        raise RuntimeError('Zig binary checksum mismatch')
    marker_data['complete'] = True
    tool_marker.write_text(json.dumps(marker_data) + '\n')
    print('Verified Zig:', binary, flush=True)
    print('Verified installed toolchain files against archive:', verified_files, flush=True)
    if args.verify_version:
        version = run([str(binary), 'version']).stdout.strip()
        if version != zig['version']:
            raise RuntimeError('Zig version mismatch')
        print('Zig version:', version, flush=True)

    verified = []
    for item in manifest['gitlinks']:
        if not item['minimal']:
            continue
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts or relative.parts[0] != 'third_party':
            raise RuntimeError('Unsafe dependency path')
        target = repo / relative
        if target.is_symlink() or not target.resolve().is_relative_to(repo):
            raise RuntimeError('Dependency target escapes repository')
        tree_line = run(['git', '--no-optional-locks', 'ls-tree', 'HEAD', '--', item['path']], cwd=repo).stdout.split()
        if len(tree_line) < 3 or tree_line[0] != '160000' or tree_line[2] != item['pin']:
            raise RuntimeError('Root Git pin differs: ' + item['path'])

        def git(*argv, data=None, check=True):
            return run(['git', '--no-optional-locks', *argv], cwd=target, data=data, check=check)

        marker = target / '.git/minimal-environment-recovery.json'
        if not (target / '.git').exists():
            if target.exists() and any(target.iterdir()):
                raise RuntimeError('Nonempty non-Git dependency target: ' + item['path'])
            target.mkdir(parents=True, exist_ok=True)
            git('init', '--quiet')
            marker.write_text(json.dumps({'url': item['url'], 'pin': item['pin']}) + '\n')
        elif not (target / '.git').is_dir():
            raise RuntimeError('External dependency Git directories are not accepted')
        origin = git('remote', 'get-url', 'origin', check=False)
        if origin.returncode:
            if not marker.exists():
                raise RuntimeError('Existing dependency lacks a known origin or recovery marker')
            git('remote', 'add', 'origin', item['url'])
        elif origin.stdout.strip() != item['url']:
            raise RuntimeError('Dependency origin mismatch')
        head = git('rev-parse', '--verify', 'HEAD', check=False)
        if head.returncode == 0:
            if head.stdout.strip() != item['pin'] or git('status', '--porcelain=v1').stdout:
                raise RuntimeError('Existing dependency differs or has edits; refusing to overwrite')
        else:
            if not marker.exists() or json.loads(marker.read_text()) != {'url': item['url'], 'pin': item['pin']}:
                raise RuntimeError('Unmarked incomplete dependency checkout')
            flags = ['--depth=1', '--no-tags']
            unicode = relative.name == 'unicodetools'
            if unicode:
                flags.append('--filter=blob:none')
            fetched = git('fetch', *flags, 'origin', item['pin'])
            if 'filtering not recognized' in fetched.stderr.lower():
                raise RuntimeError('Source does not support requested partial fetch; stopping')
            if unicode:
                git('sparse-checkout', 'set', '--no-cone', '--stdin',
                    data='\n'.join('/' + name for name in manifest['unicode_sparse_files']) + '\n')
            git('checkout', '--detach', 'FETCH_HEAD')
        if git('rev-parse', 'HEAD').stdout.strip() != item['pin'] or git('status', '--porcelain=v1').stdout:
            raise RuntimeError('Post-restore dependency validation failed')
        licenses = [str(path.relative_to(target)) for pattern in ['LICENSE*', 'COPYING*']
                    for path in target.glob(pattern) if path.is_file()]
        if not licenses:
            raise RuntimeError('No retained top-level license: ' + item['path'])
        if relative.name == 'unicodetools':
            materialized = {str(path.relative_to(target)) for path in target.rglob('*')
                            if path.is_file() and '.git' not in path.relative_to(target).parts}
            if materialized != set(manifest['unicode_sparse_files']):
                raise RuntimeError('Unicode sparse checkout differs from exact minimal scope')
        verified.append({'path': item['path'], 'pin': item['pin'], 'licenses': licenses})
        print('Verified dependency:', item['path'], item['pin'], flush=True)
    (tools / 'minimal-environment-provenance.json').write_text(json.dumps({
        'zig_version': zig['version'], 'zig_binary_sha256': zig['binary_sha256'],
        'installed_toolchain_files_verified': verified_files,
        'dependencies': verified, 'builds_or_tests_run': False,
        'excluded_dependencies': [item['path'] for item in manifest['gitlinks'] if not item['minimal']],
    }, indent=2) + '\n')
    print('Minimal environment ready. No project build or tests were run.', flush=True)


if __name__ == '__main__':
    main()
