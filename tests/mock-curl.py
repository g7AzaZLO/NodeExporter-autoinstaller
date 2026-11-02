#!/usr/bin/python3
"""Use verified release fixtures for downloads; real curl for local /metrics."""
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
url = next((arg for arg in args if arg.startswith(('https://', 'http://'))), '')
if url.startswith('https://github.com/prometheus/node_exporter/releases/download/'):
    if os.environ.get('TEST_DOWNLOAD_FAILURE'):
        sys.exit(22)
    name = url.rsplit('/', 1)[-1]
    fixture = Path('/fixtures') / name
    if not fixture.is_file():
        sys.exit(22)
    destination = Path(args[args.index('--output') + 1])
    shutil.copyfile(fixture, destination)
    if os.environ.get('TEST_CORRUPT_ARCHIVE') and name.endswith('.tar.gz'):
        with destination.open('ab') as stream:
            stream.write(b'corrupted-download')
else:
    os.execv('/usr/bin/curl', ['curl', *args])
