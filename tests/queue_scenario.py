import hashlib
import json
from pathlib import Path
import queue
import runpy
import subprocess
import sys
import tempfile
import threading
import time

source = Path(__file__).resolve().parents[1] / 'model_gui_worker.py'
mode = sys.argv[1]
worker_message = runpy.run_path(str(source))['core']['message']
with tempfile.TemporaryDirectory(prefix='live-queue-') as temp:
    disk = Path(temp)
    root = disk / 'Models'
    root.mkdir()
    def model(key):
        data = 'fixture'
        spec = dict(rfilename='test.gguf', inline=data, size=len(data),
                    lfs={'sha256': hashlib.sha256(data.encode()).hexdigest()})
        return dict(key=key, name='Fixture '+key, quant='Q4', rev='a'*40, repo='fixture/'+key,
                    patterns=['test.gguf'], count=1, size=len(data), roles='HDD', resolvedFiles=[spec])
    entries = {k: model(k) for k in ['101', '102', '103', '104']}
    original = ['101', '102'] if mode in ('transition', 'steady', 'row-controls') else ['101']
    (root/'.download-queue.json').write_text(json.dumps([entries[k] for k in original]))
    fixture = r'''
import json, pathlib, runpy, sys, time
source, disk = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
mode = sys.argv[3]
sys.argv = [str(source)]
worker = runpy.run_path(str(source))
core = worker["core"]
entries = json.loads((disk/'fixture.json').read_text())
core["catalog"] = lambda: entries
real_preview, real_download = core["preview_queue"], core["download"]
def wait_for(name):
    limit = time.monotonic()+5
    while not (disk/name).exists():
        if time.monotonic()>limit: raise RuntimeError("test timed out waiting for "+name)
        time.sleep(0.01)
def preview(models, *args, **kwargs):
    if any(m['key'] == '103' for m in models) and not (disk/'editing').exists() and mode in ('transition', 'last'):
        (disk/'editing').touch()
        wait_for('continue-edit')
    return real_preview(models, *args, **kwargs)
def download(m, *args):
    if m['key'] in ('101', '102'):
        (disk/('transfer-'+m['key'])).touch()
        wait_for('finish-'+m['key'])
    return real_download(m, *args)
core["download"], core["preview_queue"] = download, preview
if mode == "space":
    usage = real_preview.__globals__['shutil']
    real_disk_usage = usage.disk_usage
    usage.disk_usage = lambda p: real_disk_usage(p)._replace(free=14)
worker["main"]()
'''
    (disk/'fixture.json').write_text(json.dumps(entries))
    p = subprocess.Popen([sys.executable,'-u','-c',fixture,str(source),str(disk),mode],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = queue.Queue()
    trace = []
    def read():
        for line in p.stdout:
            trace.append(line.rstrip())
            if line.startswith('@@'):
                output.put(json.loads(line[2:]))
        output.put(None)
    threading.Thread(target=read, daemon=True).start()
    def send(line):
        p.stdin.write(line+'\n')
        p.stdin.flush()
    def event(*kinds):
        while True:
            value = output.get(timeout=6)
            if value is None: raise AssertionError('worker exited before '+str(kinds)+'\n' +' | '.join(trace))
            if value['event'] in kinds: return value
    def wait_for(name):
        limit = time.monotonic()+5
        while not (disk/name).exists():
            if time.monotonic()>limit: raise AssertionError('timeout: '+name)
            time.sleep(0.01)
    try:
        request = dict(disk=str(disk), ids=original, previous=original, resume=True)
        if mode == 'row-controls':
            request['resumeFirst'] = '102'
        send(json.dumps(request))
        event('ready')
        send('start')
        q = event('queue')
        if mode == 'row-controls':
            assert q['pending'] == ['102', '101'], q
            wait_for('transfer-102')
            send(json.dumps({'pauseModel':'101'}))
            assert event('editError', 'pausing')['event'] == 'editError'
            send(json.dumps({'pauseModel':'102'}))
            event('pausing')
            p.wait(timeout=3)
            saved = json.loads((root/'.download-queue.json').read_text())
            assert [m['key'] for m in saved] == ['102', '101']
            assert saved[0]['downloadStarted'] and not saved[1].get('downloadStarted')
            sys.exit(0)
        wait_for('transfer-101')
        command = dict(append=['104', '103', '104'] + original)
        send(json.dumps(command))
        if mode == 'space':
            result = event('queue','editError')
            expected = worker_message('Недостаточно места для изменённой очереди.')
            assert result['event']=='editError' and result['message'] == expected, result
            assert [m['key'] for m in json.loads((root/'.download-queue.json').read_text())] == original
            (disk/'finish-101').touch()
        elif mode == 'steady':
            appended = event('queue', 'editError')
            assert appended.get('ack') and appended.get('pending') == ['101','102','104','103'], appended
            assert not appended['finished']
            send(json.dumps(command))
            repeated = event('queue', 'editError')
            assert repeated.get('ack') and repeated['pending'] == appended['pending']
            (disk/'finish-101').touch()
            (disk/'finish-102').touch()
        else:
            wait_for('editing')
            (disk/'finish-101').touch()
            changed = event('queue','editError')
            assert changed.get('finished') == ['101'], changed
            (disk/'continue-edit').touch()
            appended = event('queue','editError')
            assert appended.get('ack') and appended.get('pending') == original[1:]+['104','103'], appended
            if mode == 'transition':
                assert [m['key'] for m in json.loads((root/'.download-queue.json').read_text())] == ['102','104','103']
                (disk/'finish-102').touch()
        event('complete')
        assert json.loads((root/'.download-queue.json').read_text()) == []
        if mode != 'space':
            for key in ['104', '103']:
                assert len(list((root/'Other').glob(f'*{key}*/test.gguf'))) == 1
        print('PASS', mode)
    finally:
        p.stdin.close()
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
