"""Offline regression tests. Run with python3 -m unittest discover -s tests."""
from contextlib import redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase, mock
import hashlib
import io
import json
import runpy
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
worker = runpy.run_path(str(ROOT / 'model_gui_worker.py'))
core = worker['core']


def spec(name, content):
    return dict(rfilename=name, inline=content, size=len(content),
                lfs=dict(sha256=hashlib.sha256(content.encode()).hexdigest()))


def model(files):
    return dict(key='1001', repo='demo/test', rev='f'*40, name='Test', quant='Q4',
                roles='HDD', purposes=['Код'], count=len(files), size=sum(f['size'] for f in files),
                patterns=[f['rfilename'] for f in files], resolvedFiles=files, personal=True)


class StorageTests(TestCase):
    def test_loose_gguf_requires_real_tensor_data(self):
        with TemporaryDirectory() as tmp:
            disk = Path(tmp)
            folder = disk/'Models'
            folder.mkdir()
            (folder/'Library Sample.gguf').write_bytes(b'GGUF' + bytes(64))
            path = folder/'weights.gguf'
            header = struct.pack('<4sIQQ', b'GGUF', 3, 1, 0)
            descriptor = struct.pack('<Q', 1) + b'w' + struct.pack('<IQIQ', 1, 2, 0, 0)
            content = header + descriptor
            content += bytes(-len(content) % 32) + struct.pack('<ff', 1, 2)
            path.write_bytes(content[:-1])
            self.assertEqual(worker['installed_models'](disk), [])
            path.write_bytes(content)
            self.assertEqual(worker['installed_models'](disk), [
                dict(name='weights.gguf', detail='GGUF', path=str(path), size=len(content))])

    def test_planning_creates_folders_and_preserves_queue(self):
        m = model([spec('m.gguf', 'test')])
        other = dict(m, key='1002')
        with TemporaryDirectory() as tmp:
            disk = Path(tmp)
            state = disk/'Models'/'.download-queue.json'
            state.parent.mkdir()
            state.write_text('[{"key":"already queued"}]')
            with mock.patch.dict(core, PERSONAL=disk/'settings'/'models.json', catalog=lambda:{m['key']:m}):
                worker['prepare_favorites'](disk, [other])
                request = dict(action='planFavorite', key=m['key'], disk=tmp)
                preview = dict(request, action='favoriteDestination')
                with mock.patch('sys.stdin', io.StringIO(json.dumps(preview))):
                    path = Path(worker['import_request']())
                self.assertFalse(path.exists())
                with mock.patch('sys.stdin', io.StringIO(json.dumps(request))):
                    self.assertEqual(worker['import_request'](), m)
                again = worker['prepare_favorites'](disk, [m])
                self.assertEqual(path, Path(again[0]['folder']))
                self.assertFalse(again[0]['created'])
                self.assertTrue(Path(again[0]['folder']).is_dir())
                self.assertEqual(json.loads((disk/'settings/favorite-storage.json').read_text()),
                                 {m['key']:str(disk.resolve()),other['key']:str(disk.resolve())})
                self.assertEqual(worker['installed_models'](disk), [])
            self.assertEqual(state.read_text(), '[{"key":"already queued"}]')

    def test_browser_favorite_preview_uses_selected_drive_and_purpose(self):
        entry = model([spec('m.gguf','test')])
        with TemporaryDirectory() as tmp:
            disk = Path(tmp)/'Custom folder'
            disk.mkdir()
            request = dict(action='favoriteDestination', disk=str(disk), repo=entry['repo'],
                           revision=entry['rev'], variant=entry['quant'], files=entry['patterns'],
                           size=entry['size'], purposes=['Анализ изображений'])
            for catalog in ({}, {entry['key']:entry}):
                with mock.patch.dict(core,catalog=lambda:catalog), mock.patch('sys.stdin', io.StringIO(json.dumps(request))):
                    preview = Path(worker['import_request']())
                expected = dict(entry, purposes=request['purposes'])
                if not catalog:
                    expected.update(key='1000', name='test')
                self.assertEqual(preview, core['model_folder'](expected, disk, reuse_equivalent=False))
                self.assertEqual(preview.parent, disk/'Models'/'Image Analysis')
                self.assertFalse(preview.exists())

    def test_inventory_requires_all_final_files_and_assembled_parts(self):
        files = [spec('m.gguf.part1of2', 'a'), spec('m.gguf.part2of2','b'), spec('mmproj.gguf','pr')]
        m = model(files)
        with TemporaryDirectory() as tmp, mock.patch.dict(core, catalog=lambda:{m['key']:m}):
            disk = Path(tmp)
            folder = core['model_folder'](m,disk)
            folder.mkdir(parents=True)
            core['model_files'](m,folder,cache=True)
            (folder/'m.gguf.partial').write_text('ab')
            (folder/'mmproj.gguf').write_text('pr')
            self.assertEqual(worker['installed_models'](disk), [])
            (folder/'m.gguf.partial').rename(folder/'m.gguf')
            self.assertEqual(worker['installed_models'](disk),
                             [dict(name=m['name'],detail='Q4',path=str(folder),size=4)])
            (folder/'mmproj.gguf').write_text('p')
            self.assertEqual(worker['installed_models'](disk), [])

    def test_nested_raw_and_regular_shards(self):
        files = [spec(f'sub/m.gguf.part{i}of3', str(i)) for i in [2,3,1]]
        files += [spec(f'model-{i:05d}-of-00002.gguf', str(i)) for i in [1,2]]
        files += [spec('mmproj.gguf','projector')]
        m = model(files)
        with TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            disk = Path(tmp)
            for _ in range(2):  # including an already assembled model
                core['download'](m, disk)
                folder = core['model_folder'](m, disk)
                self.assertEqual((folder/'sub/m.gguf').read_bytes(), b'123')
                self.assertFalse(list(folder.rglob('*.part*')))
                self.assertTrue((folder/'model-00001-of-00002.gguf').exists())
                self.assertEqual(core['space_for_model'](m, folder, files)[0],0)

    def test_variant_keys_sizes_and_focus(self):
        projector = spec('mmproj-f16.gguf', 'pr')
        small = model([spec('demo-Q4_K_M.gguf', 'four'), projector])
        large = dict(model([spec('demo-Q8_0.gguf', 'eight')]), key='1002')
        files = {f['rfilename']:f['size'] for m in (small,large) for f in m['resolvedFiles']}
        files['demo-IQ2.gguf'] = 2
        with mock.patch.dict(core, catalog=lambda:{m['key']:m for m in (small,large)}):
            for focus, label in (('',small['patterns'][0]), (large['patterns'][0],large['patterns'][0])):
                plan = worker['file_options'](small['repo'],small['rev'],files,focus)
                self.assertEqual(plan['options'][plan['preferred']]['label'],label)
                self.assertEqual(plan['extras'],[dict(name='mmproj-f16.gguf',size=2)])
                self.assertEqual([(o.get('keys'),o['size']) for o in plan['options']],
                                 [(None,2),(['1001'],4),(['1002'],5)])

    def test_search_locations_and_destination_on_two_drives(self):
        a = model([spec('q4.gguf','four'),spec('mmproj.gguf','pr')])
        b = dict(model([spec('q8.gguf','eight')]),key='1002',quant='Q8')
        with TemporaryDirectory() as tmp, mock.patch.dict(core, catalog=lambda:{m['key']:m for m in (a,b)}):
            first, second = (Path(tmp)/n for n in ('One','Two'))
            folder = core['model_folder'](a,first)
            folder.mkdir(parents=True)
            core['model_files'](a,folder,cache=True)
            for f in a['resolvedFiles']:
                (folder/f['rfilename']).write_text(f['inline'])
            (second/'Models').mkdir(parents=True)
            (second/'Models/.download-queue.json').write_text(json.dumps([dict(b,downloadStarted=True)]))
            rows = worker['variant_locations']([str(first),str(second)])
            self.assertEqual([(r['state'],r['key'],r['disk']) for r in rows],
                             [('installed',a['key'],str(first)),('paused',b['key'],str(second))])
            self.assertEqual(rows[0]['files'],a['patterns'])
            request = dict(action='destination',disk=str(second),repo=b['repo'],revision=b['rev'],
                           variant=b['quant'],files=b['patterns'],size=b['size'],purposes=b['purposes'],includeMatch=True)
            with mock.patch('sys.stdin',io.StringIO(json.dumps(request))):
                result = worker['import_request']()
            self.assertGreater(result['freeBytes'],0)
            self.assertEqual(result['key'],b['key'])
            self.assertTrue(second in Path(result['path']).parents)

    def test_incomplete_import(self):
        for name in ('a-00001-of-00002.gguf','a.gguf.part2of3'):
            with self.assertRaises(ValueError):
                worker['file_options']('demo/test','f'*40,{name:1})
            plan = worker['file_options']('demo/test','f'*40,{name:1,'complete.gguf':1})
            self.assertEqual([o['label'] for o in plan['options']],['complete.gguf'])

    def test_same_files_reuse_registry_model(self):
        files = [spec('m.gguf','m')]
        m = model(files)
        m.update(key='10',personal=False,patterns=['*.gguf'])
        with mock.patch.dict(core,metadata=lambda *_:(m['rev'],files)):
            for source in ('Hugging Face','LM Studio'):
                plan = dict(repo=m['repo'],rev=m['rev'],source=source)
                self.assertIs(worker['matching_model']({'10':m},plan,['m.gguf'],1),m)
            self.assertIsNone(worker['matching_model']({'10':m},plan,['different.gguf'],1))

    def test_migration_preserves_partial_and_identity(self):
        m = model([spec('m.gguf','model')])
        with TemporaryDirectory() as tmp, mock.patch.dict(core['organize_models'].__globals__,catalog=lambda:{m['key']:m}):
            disk=Path(tmp)
            old=disk/'Models'/m['repo']/m['rev']/('set-'+m['key'])
            old.mkdir(parents=True)
            (old/'.download-files.json').write_text(json.dumps(dict(identity=[m['repo'],m['rev'],m['patterns']],files=m['resolvedFiles'])))
            partial = old/'m.gguf.partial'
            partial.write_bytes(b'mod')
            inode = partial.stat().st_ino
            paths=core['organize_models'](disk)
            self.assertEqual(len(paths),1)
            new=Path(paths[0])
            self.assertEqual(new.parent.name,'Coding')
            self.assertEqual((new/partial.name).stat().st_ino,inode)
            self.assertEqual(core['organize_models'](disk),[])

    def test_older_registry_number_reuses_verified_payload(self):
        m = model([spec('m.gguf','existing')])
        with TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            disk = Path(tmp)
            core['download'](m,disk)
            folder = core['model_folder'](m,disk)
            inode = (folder/'m.gguf').stat().st_ino
            curated = dict(m, key='7', personal=False, patterns=['*.gguf'])
            self.assertEqual(core['model_folder'](curated,disk), folder)
            core['download'](curated,disk)
            self.assertEqual((folder/'m.gguf').stat().st_ino,inode)
            manifest = json.loads((folder/'.download-files.json').read_text())
            self.assertEqual(manifest['identity'][2],m['patterns'])
            other = dict(curated,resolvedFiles=[spec('m.gguf','mismatch')])
            self.assertNotEqual(core['model_folder'](other,disk),folder)

    def test_failed_checksum_keeps_damaged_copy(self):
        with TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            path = Path(tmp)/'m.gguf'
            path.write_bytes(b'wrong')
            f = spec(path.name,'right')
            with self.assertRaises(ValueError): core['transfer'](path,f,'')
            core['transfer'](path,f,'')
            self.assertEqual(path.read_bytes(),b'right')
            self.assertEqual(next(path.parent.glob('*.damaged-*')).read_bytes(),b'wrong')

    def test_saved_progress_uses_local_partial_without_network(self):
        m = model([spec('m.gguf', 'payload')])
        with TemporaryDirectory() as tmp:
            disk = Path(tmp)
            folder = core['model_folder'](m, disk)
            folder.mkdir(parents=True)
            state = disk/'Models'/'.download-queue.json'
            state.write_text(json.dumps([m]))
            (folder/'m.gguf.partial').write_bytes(b'pay')
            with mock.patch.dict(core['model_files'].__globals__, metadata=mock.Mock(side_effect=AssertionError)):
                self.assertEqual(worker['saved_progress'](disk), {})
                manifest = dict(identity=[m['repo'], m['rev'], m['patterns']], files=m['resolvedFiles'])
                (folder/'.download-files.json').write_text(json.dumps(manifest))
                self.assertEqual(worker['saved_progress'](disk), {m['key']: 3})

    def test_edit_saved_queue_preserves_records_and_rejects_stale_order(self):
        with TemporaryDirectory() as tmp:
            disk = Path(tmp)
            root = disk/'Models'
            root.mkdir()
            state = root/'.download-queue.json'
            first = dict(model([spec('a.gguf', 'a')]), downloadStarted=True)
            second = dict(first, key='1002', downloadStarted=False)
            third = dict(second, key='1003')
            state.write_text(json.dumps([first, second, third]))
            previous = [m['key'] for m in (first, second, third)]
            def edit(keys):
                request = dict(action='editSavedQueue', disk=tmp, live=False, keys=keys, previous=previous)
                with mock.patch('sys.stdin', io.StringIO(json.dumps(request))):
                    return worker['import_request']()
            with self.assertRaises(ValueError):
                edit(['1001', '1001'])
            self.assertEqual(edit(['1003', '1001']), [third, first])
            with self.assertRaises(ValueError):
                edit([])
            self.assertEqual(json.loads(state.read_text()), [third, first])

    def test_saved_queue_runs_in_real_worker(self):
        with TemporaryDirectory() as tmp:
            disk=Path(tmp); root=disk/'Models'; root.mkdir()
            m=model([spec('m.gguf','one')])
            state=root/'.download-queue.json'
            state.write_text(json.dumps([m]))
            request=dict(disk=str(disk),ids=[m['key']],previous=[m['key']],resume=True)
            p=subprocess.run([sys.executable,str(ROOT/'model_gui_worker.py')],
                             input=json.dumps(request)+'\nstart\n',capture_output=True,text=True,timeout=10)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            events=[json.loads(l[2:])['event'] for l in p.stdout.splitlines() if l.startswith('@@')]
            self.assertEqual(events[-1],'complete')
            self.assertEqual(json.loads(state.read_text()),[])

    def test_batch_at_transfer_boundaries(self):
        for scenario in ('steady', 'transition', 'last', 'space', 'row-controls'):
            with self.subTest(scenario=scenario):
                job = subprocess.run([sys.executable,str(Path(__file__).with_name('queue_scenario.py')),scenario],
                                     text=True,capture_output=True,timeout=15)
                self.assertEqual(job.returncode,0,job.stdout+job.stderr)
