"""Owned immutable SFTP peer with enough real IO slices to pause mid-file.
Run with the same --out contract as sftp_conflict_loopback.py. No remote write.
"""
import time
import sftp_conflict_loopback as fixture
fixture.PAYLOAD = b"ZEROWORK_MULTIWINDOW_RETAINED_V1\n" + bytes(range(256)) * 32768
_original_read = fixture.Handle.read
def bounded_read(self, offset, length):
    time.sleep(0.025)
    return _original_read(self, offset, length)
fixture.Handle.read = bounded_read
fixture.main()
