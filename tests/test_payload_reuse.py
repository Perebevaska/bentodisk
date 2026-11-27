"""Exercise local package reuse without fetching any third-party files."""
from contextlib import redirect_stdout
import hashlib
import io
from pathlib import Path
import runpy
from tempfile import TemporaryDirectory
from unittest import TestCase, mock

core = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'Скачать модели.command'))
engine = core['download'].__globals__


def file(name, text):
    return dict(rfilename=name, inline=text, size=len(text), lfs={'sha256':hashlib.sha256(text.encode()).hexdigest()})


def package(key, files):
    return dict(key=key, repo='fixture/vision', rev='a'*40, name='Vision', quant=key,
                count=len(files), size=sum(f['size'] for f in files), purposes=['Анализ изображений'],
                patterns=[f['rfilename'] for f in files], resolvedFiles=files)


class PayloadReuseTests(TestCase):
    def setUp(self):
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.disk = Path(temp.name)
        self.weights = file('Q4.gguf', 'weights')
        self.projector = file('mmproj.gguf', 'projector')
        silence = redirect_stdout(io.StringIO())
        silence.__enter__()
        self.addCleanup(silence.__exit__, None, None, None)

    def install(self, m):
        core['download'](m, self.disk)
        return core['model_folder'](m, self.disk)

    def test_text_only_in_precreated_favorite(self):
        both = package('1001',[self.weights, self.projector])
        before = self.install(both)
        text = package('1002',[self.weights])
        after = core['model_folder'](text,self.disk,canonical=True)
        after.mkdir(parents=True)
        with mock.patch.dict(engine, volume_copy_mode=lambda path:'hardlink'):
            self.assertEqual(core['payload_budget'](text,self.disk,after,text['resolvedFiles']), (0,0,0))
            with mock.patch.dict(engine, transfer=mock.Mock(side_effect=AssertionError('repeated transfer'))):
                self.assertEqual(self.install(text),after)
        self.assertTrue((before/'Q4.gguf').samefile(after/'Q4.gguf'))
        self.assertEqual(core['integrity_status'](before,both,both['resolvedFiles']), 'verified')
        self.assertEqual(core['integrity_status'](after,text,text['resolvedFiles']), 'verified')

    def test_initial_favorite_can_reuse_equivalent_old_number(self):
        source = package('1001',[self.weights])
        original = self.install(source)
        target = dict(source,key='7',quant='curated',patterns=['*.gguf'])
        favorite = core['model_folder'](target,self.disk,canonical=True)
        favorite.mkdir(parents=True)
        remaining = []
        self.assertTrue(core['preview_queue']([target],self.disk,lambda m,n:remaining.append(n)))
        self.assertEqual(remaining,[0])
        with mock.patch.dict(engine, transfer=mock.Mock(side_effect=AssertionError('repeated transfer'))):
            self.assertEqual(self.install(target),favorite)
        self.assertEqual((favorite/'Q4.gguf').read_bytes(),(original/'Q4.gguf').read_bytes())

    def test_assembled_parts_and_copy_volume_budget(self):
        parts = [file('sub/m.gguf.part1of2','one'),file('sub/m.gguf.part2of2','two')]
        original = self.install(package('1001',parts))
        m = package('1002',parts + [self.projector])
        target = core['model_folder'](m,self.disk)
        with mock.patch.dict(engine,volume_copy_mode=lambda p:'copy'):
            self.assertEqual(core['payload_budget'](m,self.disk,target,m['resolvedFiles']),(9,15,0))
            with mock.patch.dict(engine,transfer=mock.Mock(wraps=core['transfer'])):
                transfer = engine['transfer']
                self.install(m)
                self.assertEqual([call.args[1]['rfilename'] for call in transfer.call_args_list], ['mmproj.gguf'])
        self.assertEqual((target/'sub/m.gguf').read_bytes(),b'onetwo')
        self.assertFalse((original/'sub/m.gguf').samefile(target/'sub/m.gguf'))
        self.assertEqual(core['integrity_status'](target,m,m['resolvedFiles']), 'verified')

    def test_unmanaged_lm_uses_pinned_hash_and_preserves_bad_source(self):
        repo = self.disk/'.lmstudio/models/fixture/vision'
        repo.mkdir(parents=True)
        local = repo/'Q4.gguf'
        local.write_bytes(b'weights')
        m = package('1001',[self.weights,self.projector])
        with mock.patch.object(Path,'home',return_value=self.disk):
            target = core['model_folder'](m,self.disk)
            self.assertEqual(core['payload_budget'](m,self.disk,target,m['resolvedFiles'])[0],9)
            with mock.patch.dict(engine,transfer=mock.Mock(wraps=core['transfer'])):
                transfer = engine['transfer']
                self.install(m)
                self.assertEqual([call.args[1]['rfilename'] for call in transfer.call_args_list],['mmproj.gguf'])
            # Different pinned revision isolates this case from the first managed copy.
            m = dict(m,rev='c'*40)
            local.write_bytes(b'corrupt')
            with mock.patch.dict(engine,transfer=mock.Mock(wraps=core['transfer'])):
                transfer = engine['transfer']
                actual = self.install(m)
                self.assertEqual(len(transfer.call_args_list),2)
            self.assertEqual(local.read_bytes(),b'corrupt')
            self.assertEqual((actual/'Q4.gguf').read_bytes(),b'weights')

    def test_changed_and_older_installation(self):
        m = package('1001',[self.weights])
        folder = self.install(m)
        self.assertEqual(core['integrity_status'](folder,m,m['resolvedFiles']), 'verified')
        (folder/'Q4.gguf').write_bytes(b'changed')
        self.assertEqual(core['integrity_status'](folder,m,m['resolvedFiles']), 'changed')
        (folder/'.download-verified.json').unlink()
        self.assertEqual(core['integrity_status'](folder,m,m['resolvedFiles']), 'size')

    def test_donor_exemption_requires_explicit_external_shard(self):
        m = core['catalog']()['30']
        name = 'test-00001-of-00009.gguf'
        self.assertEqual(core['file_groups']([dict(rfilename=name)],model=m),{})
        for patterns in (['*.gguf'],['*00001-of-00009.gguf'],['upstream/donor@'+'a'*40+'::*-*-of-00009.gguf']):
            with self.assertRaises(ValueError):
                core['file_groups']([dict(rfilename=name)],model={'patterns':patterns})
        with self.assertRaises(ValueError):
            core['file_groups']([dict(rfilename='test-00002-of-00009.gguf')],model=m)
