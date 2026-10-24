"""Bounded, authenticated-by-caller, retry-safe batch evidence reassembly."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import re
import threading
import uuid

PART_SIZE = 512 * 1024
MAX_SIZE = 256 * 1024 * 1024

class UploadConflict(ValueError):
    pass

class UploadParts:
    def __init__(self, root: Path):
        self.root = root
        self.guard = threading.Lock()
        self.locks = {}

    def receive(self, job: str, name: str, index: int, total: int, count: int,
                digest: str, part_digest: str, data: bytes, destination: Path) -> dict:
        if not re.fullmatch(r"[a-f0-9]{32}", job) or not re.fullmatch(r"batch-[a-z0-9-]{1,48}\.zip", name):
            raise ValueError("invalid archive identity")
        if not 0 < total <= MAX_SIZE or count != (total + PART_SIZE - 1) // PART_SIZE or not 0 <= index < count:
            raise ValueError("invalid part layout")
        if not re.fullmatch(r"[a-f0-9]{64}", digest) or not re.fullmatch(r"[a-f0-9]{64}", part_digest):
            raise ValueError("invalid digest")
        if len(data) != min(PART_SIZE, total - index * PART_SIZE) or hashlib.sha256(data).hexdigest() != part_digest:
            raise ValueError("truncated or corrupt part")
        metadata = dict(total=total, count=count, sha256=digest)
        key = (job, name)
        with self.guard:
            lock = self.locks.setdefault(key, threading.Lock())
        with lock:
            directory = self.root / job / name
            path = directory / "metadata.json"
            record = json.loads(path.read_text()) if path.exists() else {**metadata, "parts": {}, "complete": False}
            if any(record[k] != v for k, v in metadata.items()):
                raise UploadConflict("archive metadata changed")
            previous = record["parts"].get(str(index))
            if previous is not None and previous != part_digest:
                raise UploadConflict("part changed during retry")
            if record["complete"]:
                return {"complete": True, "sha256": digest, "size": total}
            directory.mkdir(parents=True, exist_ok=True)
            if previous is None:
                temporary = directory / (uuid.uuid4().hex + ".tmp")
                temporary.write_bytes(data)
                temporary.replace(directory / str(index))
                record["parts"][str(index)] = part_digest
            if len(record["parts"]) == count:
                destination.parent.mkdir(parents=True, exist_ok=True)
                temporary = destination.with_name(destination.name + "." + uuid.uuid4().hex + ".tmp")
                sha = hashlib.sha256()
                size = 0
                try:
                    with temporary.open("wb") as output:
                        for number in range(count):
                            with (directory / str(number)).open("rb") as source:
                                while chunk := source.read(1024 * 1024):
                                    output.write(chunk)
                                    sha.update(chunk)
                                    size += len(chunk)
                    if size != total or sha.hexdigest() != digest:
                        raise ValueError("complete archive digest mismatch")
                    temporary.replace(destination)
                    record["complete"] = True
                finally:
                    temporary.unlink(missing_ok=True)
            temporary = directory / (uuid.uuid4().hex + ".json.tmp")
            temporary.write_text(json.dumps(record))
            temporary.replace(path)
            if record["complete"]:
                for number in range(count):
                    (directory / str(number)).unlink(missing_ok=True)
            return {"complete": record["complete"], "sha256": digest, "size": total}
