"""Require fresh, valid, paired snapshots of every production surface."""
import hashlib
from pathlib import Path
import struct
import sys
import zlib

PAGES = {
    'main-window', 'native-sidebar', 'helper-setup', 'helper-approval', 'helper-failure', 'about', 'licenses', 'settings-general', 'settings-locations',
    'settings-permissions', 'detail-loading', 'detail-notes',
    'overview-up-to-date', 'overview-partial', 'overview-checking', 'overview-offline',
    'overview-no-matches', 'overview-first-run', 'overview-no-selection',
    *(f'detail-{name}' for name in ('shottr', 'goodnotes', 'adobe-premiere-pro-2026',
      'discord', 'obs', 'google-chrome', 'final-cut-pro', 'updater', 'raycast', 'audio-hijack')),
}

def check(folder):
    for page in sorted(PAGES):
        hashes = []
        for mode in ('light', 'dark'):
            path = folder / f'{page}-{mode}.png'
            data = path.read_bytes()
            if data[:8] != b'\x89PNG\r\n\x1a\n':
                raise ValueError(f'Invalid PNG: {path}')
            offset, compressed = 8, bytearray()
            while offset < len(data):
                size = struct.unpack('>I', data[offset:offset+4])[0]
                tag = data[offset+4:offset+8]
                body = data[offset+8:offset+8+size]
                crc = struct.unpack('>I', data[offset+8+size:offset+12+size])[0]
                if zlib.crc32(tag + body) & 0xffffffff != crc:
                    raise ValueError(f'Corrupt PNG: {path}')
                if tag == b'IHDR':
                    width, height = struct.unpack('>II', body[:8])
                    if width < 250 or height < 200:
                        raise ValueError(f'Snapshot is too small: {path}')
                if tag == b'IDAT':
                    compressed.extend(body)
                offset += size + 12
            if not compressed or not zlib.decompress(compressed):
                raise ValueError(f'PNG has no pixels: {path}')
            hashes.append(hashlib.sha256(data).hexdigest())
        if hashes[0] == hashes[1]:
            raise ValueError(f'Light and dark snapshots are identical: {page}')
    if not (folder / 'menu-bar.txt').read_text().strip():
        raise ValueError('Missing menu structure')
    print(f'PASS snapshots: {len(PAGES)} surfaces in light and dark, plus menu structure')

if __name__ == '__main__':
    check(Path(sys.argv[1]))
