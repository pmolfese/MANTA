#!/usr/bin/env python3
"""Exercise actual Receiver save/reopen code after a Debug macOS app build.

Usage: python3 MANTAReceiverTests/run_regression.py /tmp/manta-open-build
Uses a generated triangle fixture. An optional second capture-folder argument
adds a read-only audit of an existing processed capture.
Use --lidar-pass-audit CAPTURE_FOLDER for the three-pass consolidated fixture.
"""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

build = Path(sys.argv[1]).resolve() / 'Build'
arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
filelist = build / f'Intermediates.noindex/MANTA.build/Debug/MANTA Receiver.build/Objects-normal/{arch}/MANTA Receiver.LinkFileList'
objects = [p for p in filelist.read_text().splitlines() if not p.endswith('/MANTAReceiverApp.o')]
with tempfile.TemporaryDirectory(prefix='manta-receiver-tests-') as directory:
    executable = Path(directory) / 'receiver-regression'
    subprocess.run([
        'xcrun', 'swiftc', '-parse-as-library', '-target', f'{arch}-apple-macos26.0',
        '-I', str(build / 'Products/Debug'),
        str(Path(__file__).with_name('DerivativeStorageRegression.swift')),
        *objects, '-o', str(executable),
    ], check=True)
    subprocess.run([str(executable), *sys.argv[2:]], check=True)
