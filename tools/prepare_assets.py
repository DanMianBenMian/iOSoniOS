#!/usr/bin/env python3
"""Prepare the five P0 assets for the iPad app from the extracted IPSW.

Inputs (already extracted by ipsw.exe in this workspace):
  assets/raw/24A5370h__iPad13,19/kernelcache.release.iPad13,18_19
  assets/raw/j272ap.dtree                       (raw ADT, im4p payload)
  assets/raw/j272ap_fixed.dtree                 (fixed by tools/adt.py)
  assets/raw/nvram.bin

Outputs (staged into the IPA by the CI workflow):
  assets/prepared/bootkc      - raw kernelcache (img4 wrapper stripped if present)
  assets/prepared/dtree       - fixed ADT
  assets/prepared/nvram.bin   - CHRP NVRAM image
  assets/prepared/ramdisk.dmg - RestoreRamDisk (from IPSW, may be large)
  assets/prepared/trustcache  - derived from ramdisk binaries (optional for P1)

The kernelcache is an IMG4/im4p container; darwin-vm's get_files.sh strips it.
We use ipsw.exe for the same job on Windows.
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, 'assets', 'raw')
OUT = os.path.join(ROOT, 'assets', 'prepared')
IPSW_TOOL = r'D:\RyBoxFirmware\tools\ipsw.exe'
IPSW = r'D:\i4Tools9\Firmware\iPad_Fall_2022_27.0_24A5370h_Restore.ipsw'


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def copy_asset(src, name, manifest):
    if not os.path.isfile(src):
        print(f'  MISSING {name}: {src}')
        return False
    dst = os.path.join(OUT, name)
    shutil.copyfile(src, dst)
    manifest[name] = {'sha256': sha256(dst), 'bytes': os.path.getsize(dst)}
    print(f'  staged {name}: {os.path.getsize(dst)} bytes sha256={manifest[name]["sha256"][:16]}…')
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ipsw-tool', default=IPSW_TOOL)
    ap.add_argument('--ipsw', default=IPSW)
    ap.add_argument('--skip-ramdisk', action='store_true',
                    help='ramdisk is multi-GB; skip for the P1 smoke build')
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    manifest = {}

    print('Staging fixed ADT / NVRAM:')
    copy_asset(os.path.join(RAW, 'j272ap_fixed.dtree'), 'dtree', manifest)
    copy_asset(os.path.join(RAW, 'nvram.bin'), 'nvram.bin', manifest)

    print('Extracting raw kernelcache payload:')
    kc_raw = os.path.join(RAW, '24A5370h__iPad13,19', 'kernelcache.release.iPad13,18_19')
    kc_out = os.path.join(OUT, 'bootkc')
    if os.path.isfile(kc_raw):
        if os.path.isfile(args.ipsw_tool):
            subprocess.run([args.ipsw_tool, 'img4', 'im4p', 'extract',
                            '-o', kc_out, kc_raw], check=False)
        if not os.path.isfile(kc_out):
            shutil.copyfile(kc_raw, kc_out)
        manifest['bootkc'] = {'sha256': sha256(kc_out), 'bytes': os.path.getsize(kc_out)}
        print(f'  staged bootkc: {os.path.getsize(kc_out)} bytes')
    else:
        print(f'  MISSING kernelcache: {kc_raw}')

    if not args.skip_ramdisk:
        print('Extracting RestoreRamDisk (large, first-time only):')
        if os.path.isfile(args.ipsw_tool) and os.path.isfile(args.ipsw):
            subprocess.run([args.ipsw_tool, 'extract', '--device', 'iPad13,19',
                            '--dmg', 'rdisk', '-o', RAW, args.ipsw], check=False)
        # locate and normalize
        for dirpath, _, files in os.walk(RAW):
            for fn in files:
                if fn.endswith('.dmg') and ('13753' in fn or '14091' in fn or 'ramdisk' in fn.lower()):
                    copy_asset(os.path.join(dirpath, fn), 'ramdisk.dmg', manifest)
                    break

    mf = os.path.join(OUT, 'manifest.json')
    with open(mf, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(f'wrote {mf}')


if __name__ == '__main__':
    import json
    main()
