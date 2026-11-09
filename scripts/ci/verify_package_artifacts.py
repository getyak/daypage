#!/usr/bin/env python3
"""Read back the job-owned SwiftPM binary cache; never resolve or mutate it."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def inspect_cache(cache, sources, resolved):
    cache, sources = cache.resolve(strict=True), sources.resolve(strict=True)
    artifact_root = (cache / 'artifacts').resolve(strict=True)
    if not artifact_root.is_relative_to(cache):
        raise ValueError('Binary cache escapes the job-owned cache')
    pins = json.loads(resolved.read_text())['pins']
    pin, = [p for p in pins if p['identity'] == 'sentry-cocoa']
    checkout = sources / 'checkouts' / 'sentry-cocoa'
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != pin['state']['revision']:
        raise ValueError('Sentry checkout does not match Package.resolved')
    manifest = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:Package.swift'])
    if (checkout / 'Package.swift').read_bytes() != manifest:
        raise ValueError('Sentry package manifest has uncommitted changes')
    targets = re.findall(r'\.binaryTarget\(\s*name:\s*"([^"]+)",\s*url:\s*"([^"]+)",\s*checksum:\s*"([a-f0-9]{64})"', manifest.decode())
    if not targets or any(not url.startswith('https://github.com/getsentry/sentry-cocoa/releases/download/' + pin['state']['version'] + '/') for _, url, _ in targets):
        raise ValueError('Cannot validate the pinned Sentry binary manifest')
    expected = {checksum: (name, url) for name, url, checksum in targets}
    archives = []
    for path in sorted(artifact_root.rglob('*')):
        # SwiftPM uses a URL-mangled filename with a _zip suffix.
        if 'sentry' not in path.name.lower() or not path.is_file():
            continue
        real = path.resolve(strict=True)
        if not real.is_relative_to(artifact_root):
            raise ValueError('Sentry binary cache entry escapes the owned artifact directory')
        checksum = digest(real)
        if checksum not in expected:
            raise ValueError('Sentry binary cache checksum is absent from its pinned manifest')
        name, url = expected[checksum]
        archives.append({'path': str(path.relative_to(cache)), 'realPath': str(real),
                         'bytes': real.stat().st_size, 'sha256': checksum, 'target': name, 'url': url})
    if not archives:
        raise ValueError('No verified Sentry archives found in the requested binary cache')
    state_path = sources / 'workspace-state.json'
    state = json.loads(state_path.read_text())
    managed = []
    for artifact in state['object']['artifacts']:
        if artifact.get('packageRef', {}).get('identity') != 'sentry-cocoa':
            continue
        path = Path(artifact['path'])
        if not path.is_absolute():
            path = sources / path
        real = path.resolve(strict=True)
        if not real.is_relative_to(sources):
            raise ValueError('Managed Sentry artifact escapes the source-package directory')
        managed.append({'target': artifact['targetName'], 'realPath': str(real)})
    if not managed:
        raise ValueError('No extracted Sentry artifacts were read back from workspace state')
    return {'cache': str(cache), 'artifactRoot': str(artifact_root), 'revision': revision,
            'version': pin['state']['version'], 'manifestSHA256': hashlib.sha256(manifest).hexdigest(),
            'archives': archives, 'managedArtifacts': managed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--resolved', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = {'schemaVersion': 1, 'requestedCache': str(args.cache), 'verified': False}
    try:
        receipt.update(inspect_cache(args.cache, args.sources, args.resolved))
        receipt['verified'] = True
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        receipt['error'] = str(error)
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    print('Job-owned Sentry binary cache verified:', receipt['verified'])
    return 0 if receipt['verified'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
