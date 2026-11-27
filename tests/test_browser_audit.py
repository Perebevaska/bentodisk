"""Offline regressions for the real-library and cross-drive audit."""
import io
import json
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
from unittest import TestCase, mock

from test_downloader import core, model, spec, worker


def request(body):
    with mock.patch('sys.stdin', io.StringIO(json.dumps(body))):
        return worker['import_request']()


def tensor(path, name):
    header = json.dumps({name:dict(dtype="F32", shape=[1], data_offsets=[0,4])}).encode()
    path.write_bytes(struct.pack("<Q", len(header)) + header + bytes(4))


class BrowserAuditTests(TestCase):
    def test_lm_settings_move_rescan_and_offline(self):
        with TemporaryDirectory() as tmp, mock.patch.object(Path,'home',return_value=Path(tmp)):
            home = Path(tmp)
            config = home/'.lmstudio'
            config.mkdir()
            default = config/'models'
            repo = default/'author'/'Small-MLX'
            repo.mkdir(parents=True)
            (repo/'config.json').write_text('{}')
            tensor(repo/'model.safetensors','weight')
            moved = home/'Custom library'
            default.rename(moved)
            link = home/'linked models'
            link.symlink_to(moved)
            prefs = config/'settings.json'
            prefs.write_text(json.dumps({'downloadsFolder':str(link)}))
            row, = worker['variant_index']([tmp])['locations']
            self.assertEqual((row['repo'],row['path'],row['disk']),
                             ('author/Small-MLX',str((moved/'author/Small-MLX').resolve()),tmp))
            self.assertEqual(core['lm_library']({'repo':row['repo']},home), Path(row['path']))
            self.assertEqual(worker['installed_models'](home)[0]['detail'],'LM Studio · Safetensors')
            moved.rename(default)
            self.assertEqual(worker['variant_index']([tmp])['locations'],[])
            self.assertIsNone(core['lm_library']({'repo':row['repo']},home))
            prefs.unlink()
            self.assertEqual(len(worker['installed_models'](home)),1)

    def test_strata_custom_settings_and_vision_companion(self):
        with TemporaryDirectory() as tmp, mock.patch.dict('os.environ',{},clear=True):
            home = Path(tmp).resolve()
            terminal = home/'.config/strata/settings.json'
            app = home/'.local/share/strata/app-settings.json'
            for path, stamp, name in ((terminal,20,'new location'),(app,10,'old location')):
                base = home/name
                (base/'models').mkdir(parents=True)
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(dict(data_dir=str(base),data_dir_at=stamp)))
            folder = home/'new location/models'
            frame = bytearray(4100)
            frame[:8] = b'STRATA\x00\x01'
            struct.pack_into('<QQ',frame,16,4096,4)
            frame[-4:] = bytes.fromhex('28b52ffd')
            for name in ['Demo.strata','Demo-Vision.strata']:
                (folder/name).write_bytes(frame)
            (folder/'Incomplete.strata').write_bytes(frame[:128])
            with mock.patch.object(Path,'home',return_value=home):
                self.assertEqual(worker['strata_libraries'](),[folder])
                rows = worker['installed_models'](home)
                self.assertEqual([(r['name'],r['detail'],r['size']) for r in rows],
                                 [('Demo','Strata · Native + Vision',8200)])

    def test_drive_library_scopes_assignments_queue_and_downloads(self):
        items = [dict(model([spec(name+'.bin', name)]), key=str(i), name=name)
                 for i,name in enumerate(('local','waiting','other','unassigned','future'), 1)]
        local, waiting, other, _, future = items
        with TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            a, b = base/'a', base/'b'
            for drive in (a,b):
                (drive/'Models').mkdir(parents=True)
            assignments = {local['key']:str(a), waiting['key']:str(a), other['key']:str(b), future['key']:str(a)}
            (base/'favorite-storage.json').write_text(json.dumps(assignments))
            (a/'Models/.download-queue.json').write_text(json.dumps([dict(waiting,downloadStarted=True)]))
            catalog = {m['key']:m for m in items}
            with mock.patch.dict(core, catalog=lambda:catalog, PERSONAL=base/'models.json'):
                folder = core['model_folder'](local,a)
                folder.mkdir(parents=True)
                core['model_files'](local,folder,cache=True)
                (folder/'local.bin').write_text('local')
                selected = worker['drive_library']([a,a])
                self.assertEqual([m['name'] for m in selected['installed']], ['local'])
                self.assertEqual({m['name']:m['state'] for m in selected['planned']},
                                 {'waiting':'paused','future':'planned'})
                self.assertEqual([m['name'] for m in worker['drive_library']([b])['planned']], ['other'])

    def test_append_reports_actual_target_queue_under_lock(self):
        old = dict(model([spec('old.gguf','old')]), downloadStarted=True)
        new = dict(model([spec('new.gguf','new')]), key='1002')
        with TemporaryDirectory() as tmp, mock.patch.dict(core,catalog=lambda:{m['key']:m for m in (old,new)}):
            disk = Path(tmp)
            folder = disk/'Models'
            folder.mkdir()
            state = folder/'.download-queue.json'
            req = dict(disk=tmp,action='enqueue',key=new['key'],live=False,includeQueueState=True)
            self.assertFalse(request(req)['hadQueue'])
            state.write_text(json.dumps([old]))
            for _ in range(2):
                self.assertEqual(request(req),dict(hadQueue=True,model=new))
                self.assertEqual(json.loads(state.read_text()),[old,new])

    def test_empty_modelscope_and_broken_source_preserve_other_sources(self):
        g = worker['search_all_catalogs'].__globals__
        req = dict(query='SC117/Qwen',source='ModelScope',sort='downloads')
        with mock.patch.dict(g,ms_request=lambda *_:('host',dict(Models=None,TotalCount=0))):
            self.assertEqual(worker['platform_search'](req)['results'],[])
        def catalog(req):
            if req['source']=='Hugging Face':
                return dict(results=[dict(id='SC117/Qwen')],cursor='next')
            if req['source']=='ModelScope':
                return dict(results=None)
            return dict(results=[],cursor=None)
        pages = []
        with mock.patch.dict(g, search_catalog=catalog, catalog_manifest=mock.Mock(side_effect=AssertionError)):
            result = worker['search_all_catalogs'](req,pages.append)
        self.assertEqual([r['id'] for r in result['results']],['SC117/Qwen'])
        self.assertEqual(json.loads(result['cursor']),{'Hugging Face':'next'})
        self.assertIn('ModelScope',result['warnings'][0])
        self.assertEqual(len(pages),4)
        self.assertTrue(all(not p['final'] for p in pages))

    def test_fingerprints_only_for_candidates_and_cached_by_revision(self):
        hits = [dict(id='a/vision',source='Hugging Face'),dict(id='b/different-name',source='ModelScope'),
                dict(id='c/chat',source='Hugging Face')]
        def listing(key):
            size = 125 if key[1] == 'c/chat' else 100
            return '1'*40, {'model.gguf':dict(rfilename='model.gguf',size=size,lfs=dict(sha256='5'*64))}
        calls = mock.Mock(wraps=worker['manifest_fingerprint'])
        with TemporaryDirectory() as tmp, mock.patch.object(Path,'home',return_value=Path(tmp)), mock.patch.dict(
                worker['add_bundle_identities'].__globals__,catalog_manifest=listing,manifest_fingerprint=calls):
            for _ in range(2):
                rows = worker['add_bundle_identities'](hits)
                self.assertEqual(rows[0]['fingerprint'],rows[1]['fingerprint'])
                self.assertNotIn('fingerprint',rows[2])
            self.assertEqual(calls.call_count,2)
            _, manifest = listing(('hf','a/vision'))
            worker['cached_fingerprint'](('hf','a/vision'),'2'*40,manifest)
            self.assertEqual(calls.call_count,3)

    def test_complete_mlx_ignores_readme_and_partial_mlx_preserves_shards(self):
        with TemporaryDirectory() as tmp:
            home = Path(tmp)
            folder = home/'.lmstudio/models/owner/Qwen-4bit'
            folder.mkdir(parents=True)
            (folder/'config.json').write_text('{}')
            index = {'weight_map':{'one':'a.safetensors','two':'b.safetensors'}}
            (folder/'model.safetensors.index.json').write_text(json.dumps(index))
            for name in ('one','two'):
                tensor(folder/index['weight_map'][name],name)
            real = {p.name:p.stat().st_size for p in folder.iterdir()}
            remote = dict(real, **{'.gitattributes':7,'README.md':20})
            plan = worker['file_options']('owner/Qwen-4bit','d'*40,remote)
            self.assertEqual(plan['options'][0]['fileSizes'], real)
            with mock.patch.object(Path,'home',return_value=home):
                row, = worker['variant_index']([tmp])['locations']
                self.assertEqual((row['state'],row['fileSizes'],row['size']),('installed',real,sum(real.values())))
                (folder/'b.safetensors').unlink()
                row, = worker['variant_index']([tmp])['locations']
                self.assertEqual(row['state'],'partial')
                self.assertNotIn('b.safetensors',row['fileSizes'])
                self.assertEqual(worker['installed_models'](home),[])
                (folder/'a.safetensors').write_bytes(b'not weights')
                self.assertEqual(worker['variant_index']([tmp])['locations'],[])

    def test_multipart_projector_imports_all_parts(self):
        parts = ['mmproj-f16-00001-of-00002.gguf','mmproj-f16-00002-of-00002.gguf']
        sizes = dict(zip(parts,[3,4]), **{'vision.gguf':13})
        plan = worker['file_options']('owner/vision','c'*40,sizes)
        extra, = plan['extras']
        self.assertEqual(extra,dict(name='mmproj-f16.gguf',files=parts,size=7))
        with TemporaryDirectory() as tmp, mock.patch.dict(core,PERSONAL=Path(tmp)/'models.json',catalog=lambda:{}), mock.patch.dict(
                worker['register_model'].__globals__, inspect_link=lambda *_:plan):
            entry = worker['register_model'](dict(pinned='url',variant='vision.gguf',size=20,extras=[extra['name']]))
            self.assertEqual(entry['patterns'],sorted(sizes))
        del sizes[parts[0]]
        self.assertEqual(worker['file_options']('owner/vision','c'*40,sizes)['extras'],[])

    def test_failed_scan_not_empty_success_and_old_queue_reads_partial(self):
        m = model([spec('a.gguf','00000')])
        with TemporaryDirectory() as tmp, mock.patch.dict(core,catalog=lambda:{m['key']:m}):
            disk=Path(tmp)
            folder=core['model_folder'](m,disk)
            folder.mkdir(parents=True)
            core['model_files'](m,folder,cache=True)
            (folder/'a.gguf.partial').write_bytes(b'00')
            (disk/'Models/.download-queue.json').write_text(json.dumps([m]))
            missing=str(disk/'offline')
            data=worker['variant_index']([tmp,missing])
            self.assertEqual(data['failed'],[missing])
            self.assertEqual(data['locations'][0]['state'],'paused')

    def test_builtin_composite_recipe_preserves_registered_key(self):
        m=core['catalog']()['30']
        files=[dict(rfilename=f'payload-{i}.gguf',size=1) for i in range(m['count'])]
        files[-1]['size']=m['size']-len(files)+1
        with mock.patch.dict(core,metadata=lambda *_:(m['rev'],files)):
            plan=worker['file_options'](m['repo'],m['rev'],{'main.gguf':1})
            recipe=next(o for o in plan['options'] if o.get('recipeKey'))
            with mock.patch.dict(worker['register_model'].__globals__,inspect_link=lambda *_:plan):
                req=dict(pinned='url',revision=m['rev'],recipeKey=m['key'],variant=recipe['label'],size=m['size'],extras=[])
                self.assertEqual(worker['register_model'](req)['key'],m['key'])
                with self.assertRaises(ValueError):
                    worker['register_model'](dict(req,size=1))
