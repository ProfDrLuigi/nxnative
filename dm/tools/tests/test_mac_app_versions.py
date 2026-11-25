"""Mac bundle releases stay independent of the packed game display version."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
pack = module('version_pack', 'dm/mac/pack_app.py')
build = module('version_build', 'scripts/build_ipa_from_nsp.py')

class MacAppVersions(unittest.TestCase):
    def args(self, *extra):
        return pack.parse(['Test.app', '--host', 'host', '--patched', 'patched', '--romfs', 'romfs.img', '--msl', 'msl',
                           '--tables', 'tables', '--font', 'font', '--title-id', '0100BDE008218000', '--name', 'Test', *extra])

    def test_new_bundle_defaults_to_100(self):
        p = pack.info_plist(self.args('--game-version', '1.0.1'), '26.6', None)
        self.assertEqual((p['CFBundleVersion'], p['CFBundleShortVersionString']), ('1.0.0', '1.0.0'))
        self.assertEqual(p['DMGameVersion'], '1.0.1')

    def test_bundle_release_override_preserves_game_version(self):
        p = pack.info_plist(self.args('--version', '1.0.3', '--game-version', '1.9.0'), '26.6', None)
        self.assertEqual((p['CFBundleVersion'], p['CFBundleShortVersionString'], p['DMGameVersion']), ('1.0.3', '1.0.3', '1.9.0'))

    def test_unknown_game_version_does_not_use_bundle_release(self):
        p = pack.info_plist(self.args('--version', '1.0.3'), '26.6', None)
        self.assertEqual(p['DMGameVersion'], 'Unknown')

    def test_build_cli_accepts_independent_release(self):
        self.assertEqual(build.MAC_APP_VERSION, '1.0.0')
        args = build.parse_args(['--platform', 'mac-app', '--app-version', '1.0.3'])
        self.assertEqual((args.platform, args.app_version), ('mac-app', '1.0.3'))

if __name__ == '__main__': unittest.main()
