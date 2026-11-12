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
