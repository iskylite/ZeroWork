#!/usr/bin/env python3
"""Owned loopback upload peer; extends conflict fixture transport/auth auditing.
Only /fixture/upload-main.txt is writable, stored in memory and evidence files.
"""
import hashlib
import os
import stat
import paramiko
import sftp_conflict_loopback as base

TARGET = '/fixture/upload-main.txt'
OriginalState = base.State

class State(OriginalState):
    def __init__(self, output):
        super().__init__(output)
        self.upload = None

    def snapshot(self):
        value = super().snapshot()
        with self.lock:
            value['kind'] = 'owned_loopback_upload_protocol_fixture'
            value['original_source_bytes_unchanged'] = True
            value['upload'] = None if self.upload is None else {
                'path': TARGET, 'size': len(self.upload),
                'sha256': hashlib.sha256(self.upload).hexdigest(),
                'md5': hashlib.md5(self.upload).hexdigest()}
        return value

    def attrs(self, path):
        if base.normalized(path) != TARGET:
            return base.attributes(path)
        if self.upload is None:
            return paramiko.SFTP_NO_SUCH_FILE
        value = paramiko.SFTPAttributes()
        value.st_mode, value.st_size = stat.S_IFREG | 0o600, len(self.upload)
        value.st_mtime = value.st_atime = 1700000000
        return value

class Handle(paramiko.SFTPHandle):
    def __init__(self, peer, flags):
        super().__init__(flags)
        self.peer, self.state = peer, peer.state
        self.handle = f'{peer.connection}:upload:{len(self.state.opens)+1}'
        self.state.opens.append(self.handle)

    def write(self, offset, data):
        with self.state.lock:
            payload = self.state.upload
            if offset > len(payload):
                payload.extend(bytes(offset-len(payload)))
            payload[offset:offset+len(data)] = data
            (self.state.output / 'actual-upload.bin').write_bytes(payload)
        self.state.record(self.peer.connection, 'WRITE', path=TARGET, offset=offset, bytes=len(data), handle=self.handle)
        return paramiko.SFTP_OK

    def read(self, offset, length):
        with self.state.lock:
            result = bytes(self.state.upload[offset:offset+length])
        self.state.record(self.peer.connection, 'READ', path=TARGET, offset=offset, returned=len(result), handle=self.handle)
        return result

    def stat(self):
        return self.state.attrs(TARGET)

    def close(self):
        self.state.closes.append(self.handle)
        self.state.record(self.peer.connection, 'CLOSE', path=TARGET, handle=self.handle)
        return paramiko.SFTP_OK

class Files(base.Files):
    def stat(self, path):
        self.state.record(self.connection, 'STAT', path=path)
        return self.state.attrs(path)
    lstat = stat

    def list_folder(self, path):
        values = super().list_folder(path)
        if base.normalized(path) == '/fixture' and self.state.upload is not None:
            item = self.state.attrs(TARGET)
            item.filename = TARGET.rsplit('/', 1)[-1]
            values.append(item)
        return values

    def open(self, path, flags, attrs):
        if base.normalized(path) != TARGET:
            return super().open(path, flags, attrs)
        self.state.record(self.connection, 'OPEN', path=path, flags=flags)
        with self.state.lock:
            if flags & (os.O_CREAT | os.O_TRUNC):
                self.state.upload = bytearray()
            if self.state.upload is None:
                return paramiko.SFTP_NO_SUCH_FILE
        return Handle(self, flags)

class Server(base.Server):
    def check_channel_exec_request(self, channel, command):
        # Production probes the peer OS on its directory transport. Reject
        # execution, but distinguish this exact read-only probe from other execs.
        if command == b'sh -c "uname -s; cat /etc/os-release" || cmd /c ver':
            self.state.record(self.connection, 'OS_PROBE')
            return False
        return super().check_channel_exec_request(channel, command)


base.State, base.Files, base.Server = State, Files, Server
if __name__ == '__main__':
    base.main()
