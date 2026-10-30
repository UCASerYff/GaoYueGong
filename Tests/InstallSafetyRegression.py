#!/usr/bin/env python3
"""Isolated installer regression: fake apps and mocked OS commands; no real install or UI."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

INSTALLER = Path(__file__).resolve().parents[1] / 'scripts/install.sh'
APP_NAME = '搞月供.app'
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['GAO_INSTALL_FIXTURE_ROOT']).resolve()
assert str(root).startswith('/private/tmp/gaoyuegong-install-test-') and root.name.endswith('.noindex')
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps({'command': tool, 'args': args}, ensure_ascii=False) + '\n')
failure = os.environ.get('GAO_INSTALL_TEST_FAILURE', '')
def own(value):
    path = pathlib.Path(value).absolute()
    assert path.is_relative_to(root), 'Mock refuses non-fixture path: ' + str(path)
    return path
def once(name):
    marker = root / ('failed-' + name)
    if failure == name and not marker.exists():
        marker.write_text('injected failure')
        return True
    return False
if tool == 'codesign':
    app = own(args[-1])
    if '--verify' in args:
        sys.exit(1 if list(app.rglob('.invalid-signature')) else 0)
    if '--entitlements' in args:
        entitlements = app / 'Contents/entitlements.plist'
        if entitlements.exists():
            sys.stdout.buffer.write(entitlements.read_bytes())
        sys.exit(0)
    marker = app / 'Contents/team.txt'
    print('TeamIdentifier=' + (marker.read_text() if marker.exists() else '5G96498KGJ'), file=sys.stderr)
elif tool == 'pgrep':
    sys.exit(2 if failure == 'process-query' else 0 if failure == 'running' else 1)
elif tool in ['lsregister', 'pluginkit']:
    own(args[-1])
    sys.exit(17 if once(tool) else 0)
elif tool == 'killall':
    assert args == ['-TERM', 'GaoYueGongWidgets']
elif tool in ['ditto', 'mv']:
    source, target = own(args[-2]), own(args[-1])
    if tool == 'mv' and source.name.endswith('.app'):
        relative = target.relative_to(root)
        assert relative.parts[0] == 'Applications' or any(part.endswith('.noindex') for part in relative.parts[:-1])
        if source == root / 'Applications' / '搞月供.app' and once('move-original'):
            sys.exit(23)
    if tool == 'ditto' and target == root / 'Applications' / '搞月供.app' and once('target-copy'):
        target.mkdir(parents=True)
        (target / 'partial-copy').write_text('must be removed on rollback')
        sys.exit(19)
    result = subprocess.run((['/usr/bin/ditto'] if tool == 'ditto' else ['/bin/mv']) + args)
    if result.returncode:
        sys.exit(result.returncode)
    if tool == 'ditto' and '-c' in args and once('rollback-archive'):
        target.write_bytes(b'corrupt archive')
    if tool == 'ditto' and target == root / 'Applications' / '搞月供.app' and once('target-signature'):
        (target / 'Contents/.invalid-signature').write_text('invalid installed copy')
    if tool == 'ditto' and '-x' in args and target.name == 'verification' and once('rollback-extraction'):
        (target / '搞月供.app/Contents/.invalid-signature').write_text('invalid')
else:
    raise AssertionError('Unexpected system command: ' + tool)
'''


def make_app(path, version, build, payload):
    for app, identifier in [(path, 'com.gaoseries.GaoYueGong'),
                            (path / 'Contents/PlugIns/GaoYueGongWidgets.appex', 'com.gaoseries.GaoYueGong.widgets')]:
        contents = app / 'Contents'
        contents.mkdir(parents=True, exist_ok=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': identifier,
            'CFBundleShortVersionString': version,
            'CFBundleVersion': build,
        }))
        entitlements = {'com.apple.security.application-groups': ['5G96498KGJ.com.gaoseries.GaoYueGong']}
        if identifier.endswith('.widgets'):
            entitlements['com.apple.security.app-sandbox'] = True
        (contents / 'entitlements.plist').write_bytes(plistlib.dumps(entitlements))
    (path / 'Contents/payload.txt').write_text(payload)


class InstallSafetyRegression(unittest.TestCase):
    def setUp(self):
        self.fixture = Path(tempfile.mkdtemp(prefix='gaoyuegong-install-test-', suffix='.noindex', dir='/private/tmp'))
        self.addCleanup(shutil.rmtree, self.fixture)
        (self.fixture / '.gaoyuegong-install-fixture').touch()
        self.project = self.fixture / 'project'
        (self.project / 'scripts').mkdir(parents=True)
        shutil.copy2(INSTALLER, self.project / 'scripts/install.sh')
        (self.project / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '4.03', 'CFBundleVersion': '4'}))
        self.source = self.project / 'build.noindex' / APP_NAME
        self.target = self.fixture / 'Applications' / APP_NAME
        make_app(self.source, '4.03', '4', 'new program')
        make_app(self.target, '4.02', '3', 'original program')
        self.original = self.fingerprint(self.target)
        (self.fixture / 'user-data-sentinel').write_text('private records must remain unchanged')
        mockbin = self.fixture / 'mockbin'
        mockbin.mkdir()
        for command in ['codesign', 'pgrep', 'lsregister', 'pluginkit', 'killall', 'ditto', 'mv']:
            path = mockbin / command
            path.write_text(MOCK)
            path.chmod(0o755)

    @staticmethod
    def fingerprint(path):
        return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in path.rglob('*') if p.is_file()}

    def install(self, failure=''):
        environment = os.environ.copy()
        environment.update(GAO_INSTALL_FIXTURE_ROOT=str(self.fixture), GAO_INSTALL_TEST_FAILURE=failure)
        result = subprocess.run(['/bin/zsh', str(self.project / 'scripts/install.sh')], env=environment,
                                text=True, capture_output=True, timeout=45)
        self.assertEqual((self.fixture / 'user-data-sentinel').read_text(), 'private records must remain unchanged')
        self.assertFalse((self.project / '.install.noindex').exists(), result.stdout + result.stderr)
        self.assertFalse(list((self.project / 'Backups').rglob('*.app')), result.stdout + result.stderr)
        return result

    def verify_receipt(self, status):
        pointer = json.loads((self.project / 'Backups/install-latest.json').read_text())
        receipt_path = Path(pointer['receipt'])
        self.assertTrue(receipt_path.parent.name.endswith('.noindex'))
        receipt = json.loads(receipt_path.read_text())
        self.assertEqual(receipt['status'], status)
        self.assertEqual(receipt['target'], str(self.target))
        self.assertEqual((receipt['sourceVersion'], receipt['sourceBuild']), ('4.03', '4'))
        self.assertEqual((receipt['previousVersion'], receipt['previousBuild']), ('4.02', '3'))
        archive = Path(receipt['rollbackArchive'])
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), receipt['rollbackSHA256'])
        self.assertEqual(pointer['rollbackSHA256'], receipt['rollbackSHA256'])
        self.assertTrue(receipt['archiveExtractAndSignatureVerified'])
        with zipfile.ZipFile(archive, metadata_encoding='utf-8') as bundle:
            self.assertIsNone(bundle.testzip())
            self.assertEqual(bundle.read(APP_NAME + '/Contents/payload.txt'), b'original program')
        return receipt

    def assert_original(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.fingerprint(self.target), self.original)

    def test_success_keeps_verified_compressed_rollback_and_durable_pointer(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.target / 'Contents/payload.txt').read_text(), 'new program')
        receipt = self.verify_receipt('installed')
        self.assertEqual((receipt['targetVersionAfter'], receipt['targetBuildAfter']), ('4.03', '4'))

    def test_zip_input_uses_preexisting_noindex_staging(self):
        dist = self.project / 'dist'
        dist.mkdir()
        archive = dist / '搞月供-4.03.zip'
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(self.source), str(archive)], check=True)
        (dist / '搞月供-4.03.zip.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
        shutil.rmtree(self.source)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.verify_receipt('installed')

    def test_plugin_failure_restores_original_and_keeps_archive(self):
        self.assert_original(self.install('pluginkit'))
        receipt = self.verify_receipt('rolled-back')
        self.assertEqual((receipt['targetVersionAfter'], receipt['targetBuildAfter']), ('4.02', '3'))

    def test_launchservices_failure_restores_original(self):
        self.assert_original(self.install('lsregister'))
        self.verify_receipt('rolled-back')

    def test_partial_target_copy_failure_restores_original(self):
        self.assert_original(self.install('target-copy'))
        self.verify_receipt('rolled-back')

    def test_failed_initial_move_never_deletes_canonical_app(self):
        self.assert_original(self.install('move-original'))
        self.verify_receipt('failed-before-replacement')

    def test_installed_signature_failure_also_runs_exit_rollback(self):
        self.assert_original(self.install('target-signature'))
        self.verify_receipt('rolled-back')

    def test_invalid_source_signature_never_moves_original(self):
        (self.source / 'Contents/.invalid-signature').touch()
        self.assert_original(self.install())
        self.assertFalse((self.project / 'Backups').exists())

    def test_source_version_mismatch_never_moves_original(self):
        info = self.source / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleVersion'] = '999'
        info.write_bytes(plistlib.dumps(data))
        self.assert_original(self.install())
        self.assertFalse((self.project / 'Backups').exists())

    def test_wrong_extension_team_never_moves_original(self):
        (self.source / 'Contents/PlugIns/GaoYueGongWidgets.appex/Contents/team.txt').write_text('OTHERTEAM')
        self.assert_original(self.install())
        self.assertFalse((self.project / 'Backups').exists())

    def test_wrong_host_group_never_moves_original(self):
        entitlements = self.source / 'Contents/entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.application-groups': ['5G96498KGJ.wrong.group']}))
        self.assert_original(self.install())
        self.assertFalse((self.project / 'Backups').exists())

    def test_missing_widget_group_never_moves_original(self):
        entitlements = self.source / 'Contents/PlugIns/GaoYueGongWidgets.appex/Contents/entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
        self.assert_original(self.install())
        self.assertFalse((self.project / 'Backups').exists())

    def test_widget_without_sandbox_never_moves_original(self):
        entitlements = self.source / 'Contents/PlugIns/GaoYueGongWidgets.appex/Contents/entitlements.plist'
        entitlements.write_bytes(plistlib.dumps({'com.apple.security.application-groups': ['5G96498KGJ.com.gaoseries.GaoYueGong'],
                                                'com.apple.security.app-sandbox': False}))
        self.assert_original(self.install())
        self.assertFalse((self.project / 'Backups').exists())

    def test_process_query_failure_does_not_mean_app_is_stopped(self):
        self.assert_original(self.install('process-query'))
        self.assertFalse((self.project / 'Backups').exists())

    def test_bad_rollback_archive_does_not_move_original(self):
        self.assert_original(self.install('rollback-archive'))
        self.assertFalse((self.project / 'Backups/install-latest.json').exists())

    def test_failed_rollback_extraction_verification_does_not_move_original(self):
        self.assert_original(self.install('rollback-extraction'))
        self.assertFalse((self.project / 'Backups/install-latest.json').exists())


class EntitlementDisplayRegression(unittest.TestCase):
    """Run only the embedded parser; no installer, app fixture or system commands."""
    group_key = 'com.apple.security.application-groups'
    sandbox_key = 'com.apple.security.app-sandbox'
    group = '5G96498KGJ.com.gaoseries.GaoYueGong'
    abstract_host = ('[Dict]\n\t[Key] com.apple.security.application-groups\n'
                     '\t[Value]\n\t\t[Array]\n'
                     '\t\t\t[String] 5G96498KGJ.com.gaoseries.GaoYueGong\n')
    abstract_widget = ('[Dict]\n\t[Key] com.apple.security.app-sandbox\n'
                       '\t[Value]\n\t\t[Bool] true\n' + abstract_host[len('[Dict]\n'):])

    @classmethod
    def setUpClass(cls):
        script = INSTALLER.read_text()
        prefix = 'codesign -d --entitlements - "$bundle" 2>/dev/null | python3 -c \'\n'
        start = script.index(prefix) + len(prefix)
        cls.parser = script[start:script.index('\n\' "$expected_id" || return 1', start)]

    def check_parser(self, payload, accepted, widget=True):
        identifier = 'com.gaoseries.GaoYueGong' + ('.widgets' if widget else '')
        result = subprocess.run([sys.executable, '-c', self.parser, identifier],
                                input=payload, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0 if accepted else 1, result.stderr)

    def test_observed_abstract_and_xml_permissions_are_accepted(self):
        for widget, abstract in [(False, self.abstract_host), (True, self.abstract_widget)]:
            values = {self.group_key: [self.group]}
            if widget:
                values[self.sandbox_key] = True
            for payload in [abstract.encode(), plistlib.dumps(values)]:
                with self.subTest(widget=widget, abstract=payload.startswith(b'[Dict]')):
                    self.check_parser(payload, True, widget)

    def test_empty_unknown_and_duplicate_keys_are_rejected(self):
        xml = plistlib.dumps({self.group_key: [self.group], self.sandbox_key: True})
        duplicate_group = ('<key>' + self.group_key + '</key><array><string>' + self.group + '</string></array>')
        duplicate_sandbox = '<key>' + self.sandbox_key + '</key><true/>'
        cases = [b'', b'unknown format',
                 (self.abstract_widget + self.abstract_host[len('[Dict]\n'):]).encode(),
                 (self.abstract_widget + '\t[Key] ' + self.sandbox_key + '\n\t[Value]\n\t\t[Bool] true\n').encode(),
                 xml.replace(b'</dict>', duplicate_group.encode() + b'</dict>'),
                 xml.replace(b'</dict>', duplicate_sandbox.encode() + b'</dict>')]
        for index, payload in enumerate(cases):
            with self.subTest(case=index):
                self.check_parser(payload, False)

    def test_wrong_group_types_and_sandbox_values_are_rejected(self):
        wrong_groups = [self.abstract_widget.replace(self.group, 'wrong.group'),
                        self.abstract_widget.replace('\t\t[Array]\n\t\t\t[String] ', '\t\t[String] '),
                        self.abstract_widget + '\t\t\t[Bool] true\n']
        wrong_sandbox = [self.abstract_widget.replace('[Bool] true', '[Bool] false'),
                         self.abstract_widget.replace('[Bool] true', '[String] true'), self.abstract_host]
        for widget in [False, True]:
            for abstract, group_value in zip(wrong_groups, [['wrong.group'], self.group, [self.group, True]]):
                values = {self.group_key: group_value, self.sandbox_key: True}
                for payload in [abstract.encode(), plistlib.dumps(values)]:
                    with self.subTest(widget=widget, group=group_value, abstract=payload.startswith(b'[Dict]')):
                        self.check_parser(payload, False, widget)
        for abstract, sandbox in zip(wrong_sandbox, [False, 'true', None]):
            values = {self.group_key: [self.group]}
            if sandbox is not None:
                values[self.sandbox_key] = sandbox
            for payload in [abstract.encode(), plistlib.dumps(values)]:
                with self.subTest(sandbox=sandbox, abstract=payload.startswith(b'[Dict]')):
                    self.check_parser(payload, False)


if __name__ == '__main__':
    unittest.main(verbosity=2)
