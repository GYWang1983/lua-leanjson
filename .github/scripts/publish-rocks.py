#!/usr/bin/env python3
"""Publish a single release's source and two binary rocks without overwriting bytes."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile


def fetch(url, token=None, file=None, field=None):
    headers = {'User-Agent': 'lua-leanjson-release'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    body = None
    if file:
        boundary = 'leanjson-' + uuid.uuid4().hex
        headers['Content-Type'] = 'multipart/form-data; boundary=' + boundary
        body = (('--' + boundary + '\r\nContent-Disposition: form-data; name="' + field
                 + '"; filename="' + file.name + '"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
                + file.read_bytes() + ('\r\n--' + boundary + '--\r\n').encode())
    request = urllib.request.Request(url, data=body, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            result = response.read()
    except urllib.error.HTTPError as error:
        if error.code == 404 and not token:
            return None
        raise RuntimeError('HTTP ' + str(error.code) + ' from LuaRocks') from None
    if token:
        data = json.loads(result)
        if data.get('errors'):
            raise RuntimeError(str(data['errors']))
        return data
    return result


def publish(directory, version, server, token):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Expected a stable X.Y.Z release version')
    prefix = 'lua-leanjson-' + version + '-1'
    spec = directory / (prefix + '.rockspec')
    rocks = [directory / (prefix + '.' + arch + '.rock')
             for arch in ('src', 'linux-x86_64', 'linux-aarch64')]
    spec_bytes = spec.read_bytes()
    for rock in rocks:
        with zipfile.ZipFile(rock) as archive:
            if archive.read(spec.name) != spec_bytes:
                raise ValueError('Mismatched rockspec in ' + rock.name)
    files = [spec] + rocks
    # Finish all conflict checks before the first upload. Re-running a failed
    # publish may fill missing files, but must never replace different bytes.
    existing_files = {file.name: fetch(server + '/' + file.name) for file in files}
    for file in files:
        current = existing_files[file.name]
        if current is not None and current != file.read_bytes():
            raise ValueError('Refusing to overwrite different published bytes: ' + file.name)
    api = server + '/api/1/bearer/'
    query = urllib.parse.urlencode({'package': 'lua-leanjson', 'version': version + '-1'})
    current = fetch(api + 'check_rockspec?' + query, token=token)
    if current.get('version'):
        if existing_files[spec.name] is None:
            raise ValueError('Existing version rockspec is not publicly readable; retry after propagation')
        version_id = current['version']['id']
        module_url = server + '/search?q=lua-leanjson'
    else:
        created = fetch(api + 'upload', token=token, file=spec, field='rockspec_file')
        if not any(manifest.get('name') == 'root' for manifest in created.get('manifests', [])):
            raise ValueError('Package is not in the root manifest; check LuaRocks package ownership')
        version_id = created['version']['id']
        module_url = created['module_url']
    for rock in rocks:
        if existing_files[rock.name] is None:
            fetch(api + 'upload_rock/' + str(version_id), token=token, file=rock, field='rock_file')
            print('Uploaded ' + rock.name)
        else:
            print('Already identical: ' + rock.name)
    print('LuaRocks module: ' + module_url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--server', default='https://luarocks.org')
    args = parser.parse_args()
    token = os.environ.get('LUAROCKS_API_KEY') or os.environ.get('LUAROCKS_TOKEN')
    if not token:
        parser.error('Set LUAROCKS_API_KEY or LUAROCKS_TOKEN')
    try:
        publish(args.directory, args.version, args.server.rstrip('/'), token)
    except (OSError, ValueError, KeyError, RuntimeError, zipfile.BadZipFile) as error:
        print(str(error).replace(token, '[REDACTED]'), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
