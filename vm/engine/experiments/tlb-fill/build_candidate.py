"""Build an isolated exact-TLB-fill candidate and production-function checks.

No ADB, original source/object edits, APK changes or production enablement.
Layers only this memory-store change onto the known 0.2.11 native RCU link.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

from patch_tlb_fill import patch


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--engine-root', type=Path, required=True)
    p.add_argument('--rcu-candidates', type=Path, required=True)
    p.add_argument('--ndk', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    root, previous, out = a.engine_root.resolve(), a.rcu_candidates.resolve(), a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sources = Path(__file__).resolve().parent
    prepared = out/'source'
    prepared.mkdir()
    original = root/'qemu-aosp/accel/tcg/cputlb.c'
    old_hash = sha(original)
    text = original.read_text(encoding='utf-8')
    changed = patch(text)
    assert changed != text and patch(changed) == changed
    try:
        patch(text.replace('memset(env->tlb_table, -1, sizeof(env->tlb_table));', '/* drift */'))
    except ValueError:
        pass
    else:
        raise AssertionError('Missing invalidation call was accepted')
    (prepared/'cputlb.c').write_bytes(changed.encode('utf-8'))
    (prepared/'tlb_fill.h').write_bytes((sources/'tlb_fill.h').read_bytes())
    (prepared/'checks.c').write_bytes((changed+'\n'+(sources/'test_flush.c').read_text(encoding='utf-8')).encode('utf-8'))
    build = root/'qemu-aosp-build-arm64-v8a/aarch64-softmmu'
    tools = a.ndk/'toolchains/llvm/prebuilt/windows-x86_64/bin'
    def fix(v):
        return v.replace('/root/vmbuild/', root.as_posix()+'/').replace('/d/youlong-fast-build/', 'D:/youlong-fast-build/')
    def run(tool, args, name):
        rsp = out/(name+'.rsp')
        rsp.write_bytes(('\n'.join(json.dumps(str(x)) for x in args)+'\n').encode('utf-8'))
        result = subprocess.run([str(tools/tool), '@'+str(rsp)], cwd=build, capture_output=True)
        (out/(name+'.log')).write_bytes(result.stdout+result.stderr)
        if result.returncode:
            raise RuntimeError(name+' failed; see '+str(out/(name+'.log')))
        return result.stdout
    flags = [fix(v) for v in shlex.split((build/'native-flags.txt').read_text(encoding='utf-8').replace('-iquote  -iquote', '-iquote . -iquote'))]
    common = ['--target=aarch64-linux-android29', *flags]
    obj = out/'cputlb-temporal.o'
    run('clang.exe', [*common, '-c', prepared/'cputlb.c', '-o', obj], 'compile-tlb')
    test_obj = out/'checks.o'
    run('clang.exe', [*common, '-ffunction-sections', '-fdata-sections', '-c', prepared/'checks.c', '-o', test_obj], 'compile-checks')
    run('clang.exe', ['--target=aarch64-linux-android29', test_obj, '-Wl,--gc-sections', '-o', out/'check-android'], 'link-checks')
    metadata = json.loads((previous/'build.json').read_text(encoding='utf-8'))
    baseline = Path(metadata['variants']['native']['executable'])
    if sha(baseline) != metadata['variants']['native']['sha256']:
        raise ValueError('Baseline executable drift')
    args = [json.loads(line) for line in (previous/'native-link.rsp').read_text(encoding='utf-8').splitlines()]
    matches = [v for v in args if v.replace('\\', '/').endswith('/accel/tcg/cputlb.o')]
    if len(matches) != 1:
        raise ValueError('Expected one cputlb object')
    old_obj = Path(matches[0])
    old_obj_hash = sha(old_obj)
    executable = out/'qemu-tlb-temporal'
    args = [str(obj) if v == matches[0] else v for v in args]
    args[args.index('-o')+1] = str(executable)
    run('clang++.exe', args, 'candidate-link')
    run('llvm-strip.exe', ['--strip-debug', executable], 'strip-debug')
    run('llvm-objdump.exe', ['-d', '--no-show-raw-insn', '--disassemble-symbols=tlb_flush,tlb_flush_nocheck,tlb_flush_by_mmuidx_async_work', executable], 'flush-asm')
    assert sha(original) == old_hash and sha(old_obj) == old_obj_hash
    result = dict(device_contacted=False, apk_modified=False, default_enabled=False,
                  enabling_environment='VMHOST_TLB_TEMPORAL=1', minimum_android_api=29,
                  baseline=str(baseline), baseline_sha256=sha(baseline),
                  executable=str(executable), sha256=sha(executable),
                  original_source_sha256=old_hash, original_object_sha256=old_obj_hash,
                  original_files_unchanged=True, tlb_invalidation_algorithm_changed=False,
                  cpu_or_snapshot_layout_changed=False, full_system_speedup_proven=False,
                  source_sha256={f.name:sha(f) for f in sources.iterdir() if f.suffix in ('.c', '.h', '.py')})
    (out/'build.json').write_bytes((json.dumps(result, indent=2)+'\n').encode('utf-8'))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
