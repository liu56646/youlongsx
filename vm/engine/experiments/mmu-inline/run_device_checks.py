"""Reproduce paired ARM walk checks and a short real-TCG MMU workload.

No installed app launch, disk attachment, global property changes, APK install
or existing VM access. Temporary files are hash-checked and removed. A root
ADB connection capable of loading the app's public native dependencies is
required. The shell-domain results do not establish Android performance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import re
import shlex
import statistics
import subprocess
import time
import uuid


def sha(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--adb', required=True)
    p.add_argument('--serial', required=True)
    p.add_argument('--build', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=False)
    adb = [a.adb, '-s', a.serial]
    manifest = json.loads((a.build/'build.json').read_text(encoding='utf-8'))
    result = dict(full_system_speedup_proven=False, physical_tap_latency_measured=False,
                  standalone_samples=[], real_tcg_samples=[])
    paths = []
    def save():
        (a.out/'results.json').write_bytes((json.dumps(result, indent=2)+'\n').encode('utf-8'))
    def command(args, timeout=30):
        r = subprocess.run(adb+args, capture_output=True, timeout=timeout)
        if r.returncode:
            raise RuntimeError((r.stdout+r.stderr).decode(errors='replace')[-800:])
        return r.stdout.decode(errors='replace').strip()
    def shell(args):
        return command(['shell', ' '.join(map(shlex.quote, map(str, args)))])
    def state():
        raw = command(['shell', 'dumpsys battery; cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq'])
        found = re.search(r'temperature: (\d+)', raw)
        if not found:
            raise RuntimeError('Battery temperature unavailable')
        return dict(battery_c=int(found[1])/10, raw=raw)
    def guard():
        s = state()
        if s['battery_c'] >= 40.5:
            raise RuntimeError('Battery thermal guard')
        return s
    prefix = '/data/local/tmp/youlong-mmu-check-'+uuid.uuid4().hex
    def push(file, label):
        target = prefix+'-'+label
        paths.append(target)
        command(['push', str(file), target])
        shell(['chmod', '700', target])
        if shell(['sha256sum', target]).split()[0] != sha(file):
            raise RuntimeError('Device digest mismatch')
        return target
    order = ['control', 'inline', 'inline', 'control']*3
    try:
        active = subprocess.run(adb+['shell', 'pidof qemu-system-aarch64'], capture_output=True, timeout=15)
        if active.returncode not in (0, 1) or active.stdout.strip():
            raise RuntimeError('ADB failed or a VM is active; do not perturb it')
        for name in ['baseline', 'executable']:
            digest = manifest['baseline_sha256'] if name == 'baseline' else manifest['sha256']
            if sha(Path(manifest[name])) != digest:
                raise RuntimeError('Engine digest drift')
        result['before'] = guard()
        if result['before']['battery_c'] >= 38:
            raise RuntimeError('Cool phone below 38 C before this short test')
        fixtures = {name:push(a.build/(name+'-check'), name+'-check') for name in ['control','inline']}
        result['fixture_sha256'] = {name:sha(a.build/(name+'-check')) for name in fixtures}
        result['checks'] = {name:json.loads(shell(['timeout', '-s', 'KILL', '22', file])) for name,file in fixtures.items()}
        if result['checks']['control'] != result['checks']['inline']:
            raise RuntimeError('Walk results or descriptor-read trace differs')
        save()
        for name in order:
            before = guard()
            row = json.loads(shell(['timeout', '-s', 'KILL', '22', 'taskset', '40', fixtures[name], '500000']))
            result['standalone_samples'].append(dict(variant=name, before=before, **row))
            save()
        files = {'control':Path(manifest['baseline']), 'inline':Path(manifest['executable'])}
        engines = {name:push(file, name+'-engine') for name,file in files.items()}
        guest_file = a.build/'mmu-guest.elf'
        guest = push(guest_file, 'guest')
        result['guest_sha256'] = sha(guest_file)
        package = shell(['pm', 'path', 'com.vm.app']).removeprefix('package:')
        libdir = posixpath.dirname(package)+'/lib/arm64'
        for i, name in enumerate(order):
            before = guard()
            args = ['timeout', '-s', 'KILL', '8', 'taskset', '40', 'env',
                    'LD_LIBRARY_PATH='+libdir, 'VMHOST_FLATVIEW_RCU=1',
                    'VMHOST_GFX_W=16', 'VMHOST_GFX_H=16', engines[name],
                    '-machine', 'virt,gic-version=2', '-accel', 'tcg,thread=multi',
                    '-cpu', 'cortex-a57', '-smp', '1', '-m', '64M', '-display', 'none',
                    '-nodefaults', '-no-user-config', '-monitor', 'none', '-serial', 'none',
                    '-semihosting', '-device', 'loader,file='+guest+',cpu-num=0']
            started = time.monotonic()
            r = subprocess.run(adb+['shell', ' '.join(map(shlex.quote, args))], capture_output=True, timeout=13)
            text = (r.stdout+r.stderr).decode(errors='replace')
            (a.out/(f'guest-{i}-{name}.txt')).write_bytes(text.encode('utf-8'))
            m = re.search(r'MMU_GUEST_RESULT (\{[^\r\n]+\})', text)
            if r.returncode or not m or 'MMU_GUEST_FAIL' in text:
                raise RuntimeError('Guest failed; inspect raw log')
            row = json.loads(m[1])
            if row['iterations'] != 8000 or row['pages'] != 32 or row['checksum'] != 4397496755294080000:
                raise RuntimeError('Guest workload/checksum drift')
            result['real_tcg_samples'].append(dict(variant=name, before=before, measurement=row,
                guest_ns=row['ticks']*1e9/row['frequency'],
                host_seconds_including_startup=round(time.monotonic()-started, 3)))
            save()
        result['after'] = state()
        result['real_tcg_median_ms'] = {name:statistics.median(
            r['guest_ns']/1e6 for r in result['real_tcg_samples'] if r['variant']==name) for name in files}
        result['completed'] = True
        print(json.dumps(result['real_tcg_median_ms']))
    finally:
        result['cleanup'] = []
        for path in paths:
            r = subprocess.run(adb+['shell', 'rm -f '+shlex.quote(path)], capture_output=True, timeout=20)
            result['cleanup'].append(dict(path=path, removed=r.returncode == 0))
        save()


if __name__ == '__main__':
    main()
