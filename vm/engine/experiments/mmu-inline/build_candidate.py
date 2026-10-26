"""Paired native checks and a standalone QEMU ARM-regime inline candidate.

Original objects, sources and APKs remain untouched. No device access.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess

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
    local = Path(__file__).resolve().parent
    original = root/'qemu-aosp/target/arm/helper.c'
    original_hash = sha(original)
    tbi_patch = local.parents[1]/'scripts/qemu_patches/patch_arm_tb_tbi.py'
    spec = importlib.util.spec_from_file_location('tbi_patch', tbi_patch)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = module.patch(original.read_text(encoding='utf-8'))
    inline_patch = local.parents[1]/'scripts/qemu_patches/patch_arm_regime_inline.py'
    spec = importlib.util.spec_from_file_location('regime_patch', inline_patch)
    inline_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inline_module)
    changed = inline_module.patch(source)
    assert inline_module.patch(changed) == changed
    assert inline_module.configure(changed, False) == source
    assert inline_module.configure(source, False) == source
    assert inline_module.configure(changed, True) == changed
    assert changed.replace('inline __attribute__((always_inline)) uint32_t regime_el',
                           'inline uint32_t regime_el') == source
    flags_path = root/'qemu-aosp-build-arm64-v8a/aarch64-softmmu/native-flags.txt'
    build = flags_path.parent
    tools = a.ndk/'toolchains/llvm/prebuilt/windows-x86_64/bin'
    def fix(v):
        return v.replace('/root/vmbuild/', root.as_posix()+'/').replace('/d/youlong-fast-build/', 'D:/youlong-fast-build/')
    def run(tool, args, name):
        rsp = out/(name+'.rsp')
        rsp.write_bytes(('\n'.join(json.dumps(str(x)) for x in args)+'\n').encode('utf-8'))
        r = subprocess.run([str(tools/tool), '@'+str(rsp)], cwd=build, capture_output=True)
        (out/(name+'.log')).write_bytes(r.stdout+r.stderr)
        if r.returncode:
            raise RuntimeError(name+' failed; inspect log')
        return r.stdout
    flags = [fix(v) for v in shlex.split(flags_path.read_text(encoding='utf-8').replace('-iquote  -iquote', '-iquote . -iquote'))]
    flags += ['-iquote', str(root/'qemu-aosp/target/arm'), '-iquote', str(build.parent/'target/arm')]
    common = ['--target=aarch64-linux-android29', *flags]
    for label, text in [('control', source), ('inline', changed)]:
        file = out/(label+'-helper.c')
        file.write_bytes(text.encode('utf-8'))
        checks = out/(label+'-checks.c')
        checks.write_bytes((text+'\n'+(local/'test_walk.c').read_text(encoding='utf-8')).encode('utf-8'))
        obj = out/(label+'-checks.o')
        run('clang.exe', [*common, '-ffunction-sections', '-fdata-sections', '-c', checks, '-o', obj], label+'-compile-checks')
        run('clang.exe', ['--target=aarch64-linux-android29', obj, '-Wl,--gc-sections', '-o', out/(label+'-check')], label+'-link-checks')
    for name in ['mmu_guest.c', 'mmu_entry.S']:
        (out/name).write_bytes((local/name).read_bytes())
    run('clang.exe', ['--target=aarch64-none-elf', '-O2', '-ffreestanding', '-fno-builtin',
        '-mgeneral-regs-only', '-nostdlib', '-Wl,-Ttext=0x40080000', '-Wl,-e,_start',
        out/'mmu_entry.S', out/'mmu_guest.c', '-o', out/'mmu-guest.elf'], 'build-real-mmu-guest')
    obj = out/'arm-helper-inline.o'
    run('clang.exe', [*common, '-c', out/'inline-helper.c', '-o', obj], 'compile-helper')
    metadata = json.loads((previous/'build.json').read_text(encoding='utf-8'))
    baseline = Path(metadata['variants']['native']['executable'])
    if sha(baseline) != metadata['variants']['native']['sha256']:
        raise ValueError('Baseline drift')
    args = [json.loads(line) for line in (previous/'native-link.rsp').read_text(encoding='utf-8').splitlines()]
    old = str(root/'out/tb-tbi/arm-helper-tbi.o')
    if args.count(old) != 1:
        raise ValueError('Expected one baseline helper object')
    old_object_hash = sha(Path(old))
    executable = out/'qemu-mmu-inline'
    args = [str(obj) if x == old else x for x in args]
    args[args.index('-o')+1] = str(executable)
    run('clang++.exe', args, 'candidate-link')
    run('llvm-strip.exe', ['--strip-debug', executable], 'strip-debug')
    asm = {}
    names = 'get_phys_addr_lpae,get_S1prot,arm_ldq_ptw'
    for label, path in [('control', baseline), ('inline', executable)]:
        raw = run('llvm-objdump.exe', ['-d', '--no-show-raw-insn', '--disassemble-symbols='+names, path], label+'-asm')
        text = raw.decode('utf-8', errors='replace')
        asm[label] = dict(regime_el_calls=len(re.findall(r'\bbl\s+.*<regime_el>', text)),
                          instructions=len(re.findall(r'^\s*[0-9a-f]+:\s+\w', text, re.M)))
    assert sha(original) == original_hash and sha(Path(old)) == old_object_hash
    result = dict(executable=str(executable), sha256=sha(executable), baseline=str(baseline),
                  baseline_sha256=sha(baseline), device_contacted=False, apk_modified=False,
                  original_files_unchanged=True, original_source_sha256=original_hash,
                  original_object_sha256=old_object_hash, minimum_android_api=29,
                  cpu_or_snapshot_layout_changed=False, invalidation_algorithm_changed=False,
                  permission_algorithm_changed=False, runtime_speedup_proven=False,
                  function_assembly_summary=asm,
                  compiler_patch_sha256=sha(inline_patch), guest_sha256=sha(out/'mmu-guest.elf'),
                  source_sha256={f.name:sha(f) for f in local.iterdir() if f.suffix in ('.py', '.c', '.S')})
    (out/'build.json').write_bytes((json.dumps(result, indent=2)+'\n').encode('utf-8'))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
