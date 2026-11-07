import importlib.util
from pathlib import Path
import struct
import tempfile
import time
import unittest
import zlib

spec = importlib.util.spec_from_file_location('snapshot_gate', Path(__file__).resolve().parents[1] / 'check_snapshots.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

def png(colour):
    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 300, 220, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress((b'\0' + bytes([colour]) * 900) * 220)) + chunk(b'IEND', b''))

class SnapshotGateTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for page in gate.PAGES:
            for mode, colour in [('light', 255), ('dark', 0)]:
                (self.root / f'{page}-{mode}.png').write_bytes(png(colour))
        (self.root / 'menu-bar.txt').write_text('Check Now\nQuit Updater\n')

    def test_full_paired_inventory_passes(self):
        gate.check(self.root)

    def test_stale_output_cannot_pass_a_new_run(self):
        with self.assertRaisesRegex(ValueError, 'Stale snapshot'):
            gate.check(self.root, time.time() + 1)

    def test_missing_dark_surface_fails(self):
        (self.root / 'main-window-dark.png').unlink()
        with self.assertRaises(FileNotFoundError):
            gate.check(self.root)

    def test_identical_appearances_and_corruption_fail(self):
        light = self.root / 'about-light.png'
        dark = self.root / 'about-dark.png'
        dark.write_bytes(light.read_bytes())
        with self.assertRaisesRegex(ValueError, 'identical'):
            gate.check(self.root)
        dark.write_bytes(png(0)[:-10])
        with self.assertRaises((ValueError, struct.error)):
            gate.check(self.root)
