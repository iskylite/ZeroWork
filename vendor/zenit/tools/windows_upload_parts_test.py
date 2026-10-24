"""Exercise evidence retries through the real authenticated HTTP queue."""
import hashlib
import concurrent.futures
import http.client
import json
import tempfile
import threading
import socket
import unittest
import urllib.error
import urllib.request
from pathlib import Path
import windows_vm_http as queue
from windows_upload_parts import PART_SIZE

class UploadContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zenit-upload-contract-")
        self.root = Path(self.temp.name)
        self.server = queue.QueueServer(("127.0.0.1", 0), self.root)
        self.job = "a" * 32
        self.server.jobs[self.job] = {"id": self.job, "kind": "batch", "status": "running"}
        class QuietHandler(queue.Handler):
            def log_message(self, *args):
                pass
        self.server.RequestHandlerClass = QuietHandler
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:" + str(self.server.server_port)
        self.data = b"x" * PART_SIZE + b"tail"
        self.digest = hashlib.sha256(self.data).hexdigest()
        self.destination = self.root / "jobs" / self.job / "batch-fixture.zip"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def put(self, index, *, data=None, digest=None, part_digest=None, authorization=True):
        part = self.data[index * PART_SIZE:(index + 1) * PART_SIZE] if data is None else data
        headers = {"X-Upload-Size": str(len(self.data)), "X-Upload-Count": "2",
                   "X-Upload-SHA256": digest or self.digest, "X-Part-SHA256": part_digest or hashlib.sha256(part).hexdigest()}
        if authorization:
            headers["Authorization"] = "Bearer " + self.server.token
        request = urllib.request.Request(self.base + f"/upload-parts/{self.job}/batch-fixture.zip/{index}",
                                         data=part, headers=headers, method="PUT")
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            error.close()
            return error.code, None

    def test_out_of_order_and_lost_ack_retry_preserve_complete_archive(self):
        self.assertEqual(self.put(1)[1]["complete"], False)
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.put(0)[1]["complete"], True)
        self.assertEqual(self.destination.read_bytes(), self.data)
        stamp = self.destination.stat().st_mtime_ns
        self.assertEqual(self.put(0)[1]["complete"], True)
        self.assertEqual(self.destination.stat().st_mtime_ns, stamp)

    def test_conflicting_retry_cannot_overwrite_a_part(self):
        self.assertEqual(self.put(0)[0], 200)
        self.assertEqual(self.put(0, data=b"y" * PART_SIZE)[0], 409)
        self.assertEqual(self.put(1)[1]["complete"], True)
        self.assertEqual(self.destination.read_bytes(), self.data)

    def test_changed_archive_metadata_is_rejected(self):
        self.assertEqual(self.put(0)[0], 200)
        self.assertEqual(self.put(1, digest="0" * 64)[0], 409)
        self.assertFalse(self.destination.exists())

    def test_truncated_part_and_incorrect_total_digest_never_publish(self):
        self.assertEqual(self.put(0, data=b"short")[0], 400)
        self.assertEqual(self.put(0, digest="0" * 64)[0], 200)
        self.assertEqual(self.put(1, digest="0" * 64)[0], 400)
        self.assertFalse(self.destination.exists())

    def test_requires_authentication(self):
        self.assertEqual(self.put(1, authorization=False)[0], 401)
        self.assertFalse(self.destination.exists())

    def test_legacy_upload_cannot_replace_verified_batch_archive(self):
        self.put(0)
        self.assertEqual(self.put(1)[1]["complete"], True)
        request = urllib.request.Request(self.base + f"/upload/{self.job}/batch-fixture.zip",
                                         data=b"replacement", method="PUT",
                                         headers={"Authorization": "Bearer " + self.server.token})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                code = response.status
        except urllib.error.HTTPError as error:
            code = error.code
            error.close()
        self.assertEqual(code, 409)
        self.assertEqual(self.put(0)[1]["complete"], True)
        self.assertEqual(self.destination.read_bytes(), self.data)

    def test_concurrent_identical_retries_are_idempotent(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            replies = list(pool.map(lambda _: self.put(0), range(2)))
        self.assertTrue(all(code == 200 for code, _ in replies))
        self.assertEqual(self.put(1)[1]["complete"], True)
        self.assertEqual(self.destination.read_bytes(), self.data)

    def test_corrupt_part_digest_and_non_batch_job_are_rejected(self):
        self.assertEqual(self.put(0, part_digest="0" * 64)[0], 400)
        self.server.jobs[self.job]["kind"] = "probe"
        self.assertEqual(self.put(1)[0], 404)
        self.assertFalse(self.destination.exists())

    def test_disconnected_http_body_never_publishes_a_part(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.putrequest("PUT", f"/upload-parts/{self.job}/batch-fixture.zip/0")
        for key, value in {"Authorization": "Bearer " + self.server.token,
                           "Content-Length": str(PART_SIZE), "X-Upload-Size": str(len(self.data)),
                           "X-Upload-Count": "2", "X-Upload-SHA256": self.digest,
                           "X-Part-SHA256": hashlib.sha256(self.data[:PART_SIZE]).hexdigest()}.items():
            connection.putheader(key, value)
        connection.endheaders(b"partial")
        connection.sock.shutdown(socket.SHUT_WR)
        self.assertEqual(connection.getresponse().status, 400)
        connection.close()
        self.assertFalse(self.destination.exists())

if __name__ == "__main__":
    unittest.main()
