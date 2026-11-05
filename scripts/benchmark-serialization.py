#!/usr/bin/env python3
"""Isolated source/reader stage benchmark, with full output semantics checked."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--target-volume')
    parser.add_argument('--lua-directory', type=Path)
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--sources', nargs='+', choices=['memory', 'file', 'buffered-file', 'feed'], default=['memory', 'file', 'buffered-file', 'feed'])
    parser.add_argument('--policies', nargs='+', choices=['preserve', 'strict'], default=['preserve', 'strict'])
    parser.add_argument('--trials', type=int, default=21)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.trials < 3:
        parser.error('at least 3 trials required')
    repo = Path(__file__).resolve().parent.parent
    output = (args.output or Path(tempfile.mkdtemp(prefix='leanjson-serialization-'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = json.loads(subprocess.check_output(['docker', 'image', 'inspect', args.image]))[0]
    command = ['docker', 'run', '--rm', '--mount', f'type=bind,src={repo},dst=/workspace,readonly',
               '--mount', f'type=bind,src={output},dst=/measurement', '--workdir', '/workspace']
    if args.target_volume:
        command += ['--mount', f'type=volume,src={args.target_volume},dst=/workspace/target,readonly',
                    '--env', 'LD_LIBRARY_PATH=/workspace/target/release']
        library = '/workspace/target/release/libleanjson.so'
    else:
        library = '/usr/local/lib/lua/5.1/leanjson.so'
    if args.lua_directory:
        directory = args.lua_directory.resolve()
        command += ['--mount', f'type=bind,src={directory},dst=/runtime-lua,readonly']
        lua_directory = '/runtime-lua'
    else:
        lua_directory = '/usr/local/share/lua/5.1'
    native = subprocess.check_output(command + ['--entrypoint', 'sha256sum', image['Id'], library], text=True).split()[0]
    raw = args.input.read_bytes()
    if b'0123456789abcdef' not in raw:
        parser.error('input needs fixed-width marker 0123456789abcdef')
    summary = {'image_id': image['Id'], 'architecture': image['Architecture'], 'native_sha256': native,
               'lua_directory': str(args.lua_directory) if args.lua_directory else 'installed-image',
               'input_sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw),
               'methodology': 'fresh OpenResty process per source/policy; 3 warmups plus 21 trials by default; distinct fixed-width marker each trial; source write, GC, mutation and full output oracle outside timings; only decode/create/length/stream-drain timed; file_in_memory=false except buffered-file; no network or database',
               'cells': []}
    for source in args.sources:
        for policy in args.policies:
            name = source + '-' + policy
            input_file = output / (name + '-input.json')
            input_file.write_bytes(raw)
            receipt = output / (name + '-output.json')
            result = subprocess.run(command + ['--entrypoint', '/usr/local/openresty/bin/resty', image['Id'],
                '-I', lua_directory, '/workspace/benches/serialization.lua', '/measurement/' + input_file.name,
                str(args.trials), source, policy, '/measurement/' + receipt.name], capture_output=True, text=True, timeout=300)
            (output / (name + '.log')).write_text(result.stderr)
            if result.returncode:
                raise RuntimeError(name + ': ' + result.stderr)
            records = json.loads(result.stdout)
            expected = json.loads(raw.replace(b'0123456789abcdef', f'{args.trials + 101:016x}'.encode(), 1))
            expected['model'] = 'fixture-chat'
            encoded = receipt.read_bytes()
            if json.loads(encoded) != expected:
                raise AssertionError(name + ': complete output semantics mismatch')
            records['cpu_median_ms'] = {stage: statistics.median(r[stage]['cpu_ms'] for r in records['trials']) for stage in ['decode', 'create', 'length', 'emit']}
            records['wall_median_ms'] = {stage: statistics.median(r[stage]['wall_ms'] for r in records['trials']) for stage in ['decode', 'create', 'length', 'emit']}
            records['full_output_oracle'] = {'matches_input': True, 'sha256': hashlib.sha256(encoded).hexdigest(), 'bytes': len(encoded)}
            summary['cells'].append(records)
            print(name, json.dumps(records['cpu_median_ms']), flush=True)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(output / 'summary.json')


if __name__ == '__main__':
    main()
