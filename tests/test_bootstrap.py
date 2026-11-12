import hashlib
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def bootstrap_module():
    # Exercise the actual embedded Python, without running its network entrypoint.
    source = (
        (ROOT / "scripts/bootstrap-template.sh")
        .read_text()
        .split("<<'PY'\n", 1)[1]
        .rsplit("\nPY", 1)[0]
    )
    source = source.replace("@@COMMIT@@", "a" * 40).replace("@@FILES@@", "{}")
    module = types.ModuleType("bootstrap_test")
    exec(compile(source, "bootstrap.sh", "exec"), module.__dict__)  # noqa: S102 - execute repository-owned test fixture only
    return module


class DownloadTests(unittest.TestCase):
    def response(self, data, url="https://example.invalid/source"):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *unused):
                return False

            def geturl(self):
                return url

            def read(self, count):
                return data[:count]

        return Response()

    def test_corruption_and_size_limit_are_refused(self):
        module = bootstrap_module()
        for body in [b"corrupted", b"x" * (module.LIMIT + 1)]:
            with (
                patch.object(
                    module.urllib.request, "urlopen", return_value=self.response(body)
                ),
                self.assertRaises(ValueError),
            ):
                module.verified_download(
                    "https://example.invalid/source",
                    hashlib.sha256(b"expected").hexdigest(),
                )

    def test_https_and_correct_digest_required(self):
        module = bootstrap_module()
        body = b"verified source"
        digest = hashlib.sha256(body).hexdigest()
        with patch.object(
            module.urllib.request, "urlopen", return_value=self.response(body)
        ):
            self.assertEqual(
                module.verified_download("https://example.invalid/source", digest), body
            )
        with (
            patch.object(
                module.urllib.request,
                "urlopen",
                return_value=self.response(body, "http://example.invalid"),
            ),
            self.assertRaises(ValueError),
        ):
            module.verified_download("https://example.invalid/source", digest)

    def test_timeout_falls_back_and_all_payloads_must_finish(self):
        import tempfile

        module = bootstrap_module()
        module.FILES = {
            "one": hashlib.sha256(b"1").hexdigest(),
            "two": hashlib.sha256(b"2").hexdigest(),
        }
        module.SOURCES = ["https://first.invalid", "https://second.invalid"]

        def download(url, expected):
            if "first.invalid" in url:
                raise TimeoutError("transport timeout")
            return b"1" if url.endswith("/one") else b"2"

        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(module, "verified_download", side_effect=download),
        ):
            module.download_sources(Path(temporary))
            self.assertEqual((Path(temporary) / "two").read_bytes(), b"2")

    def test_corruption_does_not_fall_back_or_execute(self):
        import tempfile

        module = bootstrap_module()
        module.FILES = {"bad": "digest"}
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(
                module, "verified_download", side_effect=ValueError("corruption")
            ) as download,
            self.assertRaises(ValueError),
        ):
            module.download_sources(Path(temporary))
        self.assertEqual(download.call_count, 1)

    def test_failed_payload_prevents_launch(self):
        import tempfile

        module = bootstrap_module()
        module.FILES = {"bad": "digest"}
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(module.os, "geteuid", return_value=1000),
            patch.object(module.tempfile, "mkdtemp", return_value=temporary),
            patch.object(
                module, "verified_download", side_effect=ValueError("corruption")
            ),
            patch.object(module.os, "execvp") as execute,
            self.assertRaises(ValueError),
        ):
            module.main()
        execute.assert_not_called()

    def test_integrity_failure_cancels_queued_downloads(self):
        import tempfile
        import time

        module = bootstrap_module()
        module.FILES = {"bad": "digest", **{f"good-{n}": "digest" for n in range(20)}}
        calls = []

        def download(url, expected):
            calls.append(url)
            if url.endswith("/bad"):
                raise ValueError("corrupt")
            time.sleep(0.05)
            return b"fixture"

        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(module, "verified_download", side_effect=download),
            self.assertRaises(ValueError),
        ):
            module.download_sources(Path(temporary))
        self.assertLessEqual(
            len(calls), 5, "Queued requests continued after integrity failure"
        )
