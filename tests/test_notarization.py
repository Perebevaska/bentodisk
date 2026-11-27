"""Exercise CI failure handling without an Apple identity or network access."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'packaging uses macOS plutil and base64')
class NotarizationTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.packaging = self.root / 'packaging'
        self.packaging.mkdir()
        shutil.copy(Path(__file__).resolve().parents[1] / 'packaging/notarize-dmg.sh', self.packaging)
        binary = self.root / 'bin'
        binary.mkdir()
        self.env = dict(os.environ, PATH=f'{binary}:{os.environ["PATH"]}', RUNNER_TEMP=directory.name,
                        DEVELOPER_ID_P12_BASE64='dGVzdA==', DEVELOPER_ID_P12_PASSWORD='dummy',
                        APPLE_ID='test@example.invalid', APPLE_TEAM_ID='ABC1234567',
                        APPLE_APP_SPECIFIC_PASSWORD='dummy', TEST_STATUS='Accepted')
        def stub(name, body):
            path = binary / name
            path.write_text('#!/bin/bash\nset -eu\n' + body)
            path.chmod(0o755)
        stub('security', """
if [[ $1 == find-identity ]]; then
    echo '1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Test (ABC1234567)"'
fi
""")
        self.packaging.joinpath('build-dmg.sh').write_text('echo image > "$BENTODISK_DMG_OUTPUT"')
        stub('codesign', 'exit 0')
        stub('spctl', 'exit 0')
        stub('xcrun', """
case "$1 $2" in
    'notarytool submit') printf '{"status":"%s","id":"test-id"}' "$TEST_STATUS" ;;
    'stapler staple') echo ticket >> "$3" ;;
    'stapler validate') exit "${TEST_VALIDATE_EXIT:-0}" ;;
esac
""")

    def build(self):
        return subprocess.run(['bash', str(self.packaging / 'notarize-dmg.sh')],
                              env=self.env, capture_output=True, text=True)

    def test_missing_secret_stops_before_build(self):
        del self.env['APPLE_APP_SPECIFIC_PASSWORD']
        self.assertNotEqual(self.build().returncode, 0)
        self.assertFalse((self.root / 'dist').exists())

    def test_acceptance_and_valid_ticket_required(self):
        for status, validation, should_succeed in [('Invalid', '0', False), ('Accepted', '1', False),
                                                    ('Accepted', '0', True)]:
            with self.subTest(status=status, validation=validation):
                self.env.update(TEST_STATUS=status, TEST_VALIDATE_EXIT=validation)
                result = self.build()
                image = self.root / 'dist/BentoDisk-macOS.dmg'
                self.assertEqual(result.returncode == 0, should_succeed, result.stderr)
                self.assertEqual(image.exists(), should_succeed)
                if should_succeed:
                    self.assertEqual(image.read_text(), 'image\nticket\n')
                self.assertEqual(list(self.root.glob('bentodisk-notary.*')), [])
