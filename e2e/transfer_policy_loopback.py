"""Owned read-only peer: hold its first READ until runner releases queue evidence."""
import sftp_conflict_loopback as fixture

original = fixture.Handle.read

def gated_read(self, offset, length):
    self.state.record(self.connection, "READ_GATE", path=self.path, offset=offset, requested=length)
    while not (self.state.output / "release-reads").exists() and not self.state.stopping.wait(0.02):
        pass
    return original(self, offset, length)

fixture.Handle.read = gated_read
fixture.main()
