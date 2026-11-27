#!/usr/bin/env python3
"""Загрузчик закреплённых версий Hugging Face, Python 3.8+ и системный curl."""
import argparse
import contextvars
import ctypes
import errno
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote, urlsplit

REGISTRY = Path(__file__).resolve().with_name("Реестр моделей.md")
CURL = "/usr/bin/curl"
PERSONAL = Path.home() / "Library/Application Support/ModelDownloader/models.json"
# More specific purposes take priority for models with several labels.
MODEL_PURPOSE_FOLDERS = {
    'Управление генерацией': 'Generation Control',
    'Редактирование изображений': 'Image Editing',
    'Генерация изображений': 'Image Generation',
    'Генерация видео': 'Video Generation',
    'Распознавание текста (OCR)': 'OCR',
    'Анализ изображений': 'Image Analysis',
    'Распознавание речи': 'Speech Recognition',
    'Синтез речи': 'Text to Speech',
    'Реранжирование': 'Reranking',
    'Эмбеддинги': 'Embeddings',
    'Код': 'Coding',
    'Текст и диалог': 'Text and Chat',
    'Не указано': 'Other',
}


_translations = None

def message(key):
    """Keep CLI output in Russian by default. The GUI selects its display language."""
    if os.environ.get("MODEL_DOWNLOADER_LANGUAGE") != "en":
        return key
    global _translations
    if _translations is None:
        _translations = json.loads(Path(__file__).with_name("English.json").read_text(encoding="utf-8"))
    return _translations.get(key, key)


def catalog():
    entries = {}
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        if not re.match(r"^\| \d+ \|", line):
            continue
        key, name, quant, roles, gb, size, count, link, patterns, *extra = [
            c.strip() for c in line.strip("|").split("|")]
        repo, rev = re.fullmatch(
            r"\[[^\]]+\]\(https://huggingface\.co/([\w.-]+/[\w.-]+)/tree/([0-9a-f]{40})\)", link
        ).groups()
        if key in entries:
            raise ValueError(message('Повтор номера ') + key)
        entries[key] = dict(key=key, name=name, quant=quant, roles=roles, repo=repo,
                            rev=rev, size=int(size), count=int(count),
                            purposes=[t.strip() for t in extra[0].split(",") if t.strip()] if extra else [],
                            patterns=patterns.strip("`").split())
    if PERSONAL.exists():
        for m in json.loads(PERSONAL.read_text(encoding="utf-8")):
            if m["key"] in entries:
                raise ValueError(message('Повтор номера ') + m["key"])
            entries[m["key"]] = m
    return entries


def list_entries(entries):
    for m in entries.values():
        print(f"{m['key']:>2}. {m['name']} · {m['quant']} · {m['size']/1e9:.2f} ГБ · {m['roles']}")
    for disk in ("внешний", "внутренний", "HDD"):
        total = sum(m['size'] for m in entries.values() if disk in m['roles'].split(','))
        print(f"{disk} — {total / 1e9:.3f} ГБ")


# Only the GUI worker enables continuous retry. Queue edits run in a separate
# thread so their metadata lookups cannot overwrite the active transfer status.
network_wait = contextvars.ContextVar("network_wait", default=None)


def with_reconnect(operation, label):
    delay = 2
    while True:
        try:
            return operation()
        except subprocess.CalledProcessError as exc:
            notify = network_wait.get()
            status = (exc.output or b"").strip()
            transient = exc.returncode in {5, 6, 7, 16, 18, 28, 35, 52, 55, 56, 92, 95, 96, 97}
            if exc.returncode == 22:
                transient = status in {b"408", b"425", b"429", b"500", b"502", b"503", b"504"}
            if not notify or not transient:
                raise
            notify(label, delay)
            time.sleep(delay)
            delay = min(60, delay * 2)


def repo_metadata(repo, revision):
    url = f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"
    def fetch():
        args = [CURL, "-fsSL", "--max-time", "90", "--write-out", "\n%{http_code}", url]
        if not network_wait.get():
            args[1:1] = ["--retry", "2"]
        result = subprocess.run(args, stdout=subprocess.PIPE)
        body, _, status = result.stdout.rpartition(b"\n")
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, args, output=status)
        return body
    raw = with_reconnect(fetch, repo)
    data = json.loads(raw)
    if re.fullmatch(r'[0-9a-f]{40}', revision) and data['sha'] != revision:
        raise ValueError(message('Версия ответа отличается от реестра'))
    return data


def metadata(m, revision):
    if m.get("resolvedFiles"):
        return m["rev"], m["resolvedFiles"]
    primary = (m['repo'], revision)
    sources = {primary: repo_metadata(*primary)}
    selected = {}
    if m.get("personal"):
        items = {f["rfilename"]: f for f in sources[primary]["siblings"]}
        return sources[primary]["sha"], [items[name] for name in m["patterns"]]
    for pattern in m['patterns']:
        source = primary
        pat = pattern
        if '::' in pattern:
            ref, pat = pattern.split('::', 1)
            match = re.fullmatch(r'([\w.-]+/[\w.-]+)@([0-9a-f]{40})', ref)
            if not match:
                raise ValueError(message('Неверная ссылка на сопутствующий файл ') + ref)
            source = match.groups()
        if source not in sources:
            sources[source] = repo_metadata(*source)
        data = sources[source]
        hits = [f for f in data['siblings'] if fnmatch.fnmatchcase(f['rfilename'], pat)]
        if not hits:
            raise ValueError(message('Нет файлов по маске ') + pat)
        for f in hits:
            remote = f['rfilename']
            if Path(remote).is_absolute() or '..' in remote.split('/'):
                raise ValueError(message('Неверный путь в метаданных'))
            local = remote if source == primary else Path(remote).name
            url = f"https://huggingface.co/{source[0]}/resolve/{data['sha']}/{quote(remote)}"
            if local in selected and selected[local]['url'] != url:
                raise ValueError(message('Два файла с одинаковым именем ') + local)
            selected[local] = dict(f, rfilename=local, url=url)
    return sources[primary]['sha'], list(selected.values())


def choose_disk():
    volumes = Path('/Volumes')
    paths = [Path.home()] + sorted(p for p in volumes.iterdir()
                                    if p.is_mount() and p.resolve() != Path('/'))
    for i, p in enumerate(paths, 1):
        print(f"{i}. {p} · свободно {shutil.disk_usage(p).free/1e9:.1f} ГБ")
    answer = input("Номер диска или полный путь к существующей папке: ").strip()
    if answer.isdigit() and 1 <= int(answer) <= len(paths):
        return paths[int(answer)-1]
    p = Path(answer).expanduser()
    if not p.is_absolute() or not p.is_dir():
        raise ValueError("Выберите существующий диск или укажите полный путь")
    return p


def verify(path, spec):
    if path.stat().st_size != spec['size']:
        raise ValueError(message('Размер {0} отличается от ожидаемого').format(path))
    if 'lfs' in spec:
        digest, expected = hashlib.sha256(), spec['lfs']['sha256']
    else:
        digest, expected = hashlib.sha1(), spec['blobId']
        digest.update(f"blob {spec['size']}\0".encode())
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4*1024*1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError(message('Контрольная сумма отличается. Переместите повреждённый файл и повторите: {0}').format(path))


def partial(path):
    return path.with_name(path.name + ".partial")


def stat_if_present(path):
    try:
        return path.stat()
    except FileNotFoundError:
        return None


def transfer(path, spec, url, progress=None):
    if path.exists():
        if progress:
            progress("verify", 0)
        try:
            verify(path, spec)
        except ValueError:
            saved = path.with_name(path.name + '.damaged-' + str(time.time_ns()))
            path.rename(saved)
            raise ValueError(message('Повреждённая копия сохранена в {0}. Повторите загрузку этого файла.').format(saved))
        print(message('Уже скачан. Контрольная сумма совпала.'), flush=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = partial(path)
    if "inline" in spec:
        existing = tmp.stat().st_size if tmp.exists() else 0
        tmp.write_bytes(spec["inline"].encode())
        verify(tmp, spec)
        tmp.replace(path)
        if progress:
            progress("network", spec["size"] - existing)
            progress("verify", 0)
        return
    initial = tmp.stat().st_size if tmp.exists() else 0

    def fetch():
        offset = tmp.stat().st_size if tmp.exists() else 0
        if tmp.exists() and offset >= spec['size']:
            if progress:
                progress("network", offset - initial)
            return
        print(message('{0} · с байта {1}').format(spec['rfilename'], offset), flush=True)
        args = [CURL, "--fail", "--location", "--show-error", "--silent" if progress else "--progress-bar",
                "--connect-timeout", "30", "--speed-limit", "1", "--speed-time", "120",
                "--continue-at", "-", "--output", str(tmp), url]
        if not progress:
            subprocess.run(args, check=True)
            return
        args[1:1] = ["--write-out", "%{http_code}"]
        progress("network", offset - initial)
        with subprocess.Popen(args, stdout=subprocess.PIPE) as proc:
            try:
                while True:
                    try:
                        status, _ = proc.communicate(timeout=0.5)
                        break
                    except subprocess.TimeoutExpired:
                        written = tmp.stat().st_size if tmp.exists() else offset
                        progress("network", written - initial)
            finally:
                if proc.poll() is None:
                    proc.terminate()
        written = tmp.stat().st_size if tmp.exists() else offset
        progress("network", written - initial)
        if proc.returncode:
            raise subprocess.CalledProcessError(proc.returncode, args, output=status)
        if written < spec['size']:
            raise subprocess.CalledProcessError(18, args)

    with_reconnect(fetch, spec['rfilename'])
    if progress:
        progress("verify", 0)
    try:
        verify(tmp, spec)
    except ValueError:
        saved = tmp.with_name(tmp.name + '.damaged-' + str(time.time_ns()))
        tmp.rename(saved)
        raise ValueError(message('Повреждённая копия сохранена в {0}. Повторите загрузку этого файла.').format(saved))
    tmp.replace(path)


RAW_PART = re.compile(r"^(.+\.gguf)\.part(\d+)of(\d+)$", re.I)
GGUF_SHARD = re.compile(r"^(.+)-(\d{5})-of-(\d{5})\.gguf$", re.I)


def file_groups(files, *, model=None):
    """Return verified raw part groups. GGUF shards remain individual loadable files."""
    groups = {}
    for f in files:
        name = f['rfilename']
        match = RAW_PART.fullmatch(name) or GGUF_SHARD.fullmatch(name)
        if match:
            raw = RAW_PART.fullmatch(name) is not None
            groups.setdefault((match[1], raw), []).append((int(match[2]), int(match[3]), f))
    assembled = {}
    # A pinned external recipe may explicitly request one donor shard (Strata).
    # A wildcard shard number still denotes a complete GGUF split.
    donors = []
    for pattern in (model or {}).get('patterns', []):
        source, sep, remote = pattern.partition('::')
        name = Path(remote).name
        if sep and re.fullmatch(r'[\w.-]+/[\w.-]+@[0-9a-f]{40}', source) and GGUF_SHARD.fullmatch(name):
            donors.append(name)
    for (base, raw), items in groups.items():
        items.sort(key=lambda item: item[0])
        if not raw and len(items) == 1 and any(fnmatch.fnmatchcase(items[0][2]['rfilename'], pattern) for pattern in donors):
            continue
        if any(n != i or total != len(items) for i, (n, total, _) in enumerate(items, 1)):
            raise ValueError(message('Неполный комплект частей: ') + base)
        if raw:
            if any(f['rfilename'] == base for f in files):
                raise ValueError(message('В комплекте одновременно есть целый файл и его части: ') + base)
            assembled[base] = [f for _, _, f in items]
    return assembled


def contained(root, path):
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        raise ValueError(message('Путь выходит за пределы папки моделей'))
    return path


def require_space(folder, needed):
    free = shutil.disk_usage(folder).free
    if needed > free:
        raise ValueError(message('В {0} свободно {1:.3f} ГБ, требуется {2:.3f} ГБ').format(folder, free / 1e9, needed / 1e9))


def verify_assembled(path, parts):
    if path.stat().st_size != sum(f['size'] for f in parts):
        raise ValueError(message('Неверный размер собранной модели: {0}').format(path))
    with path.open('rb') as stream:
        for f in parts:
            if 'lfs' in f:
                digest, expected = hashlib.sha256(), f['lfs']['sha256']
            else:
                digest, expected = hashlib.sha1(), f['blobId']
                digest.update(f"blob {f['size']}\0".encode())
            left = f['size']
            while left:
                chunk = stream.read(min(left, 4 * 1024 * 1024))
                if not chunk:
                    raise ValueError(message('Обрыв файла: {0}').format(path))
                digest.update(chunk)
                left -= len(chunk)
            if digest.hexdigest() != expected:
                raise ValueError(message('В {0} повреждён участок {1}. Переместите повреждённый файл и повторите.').format(path, f['rfilename']))


def assemble_mimo(target, parts):
    if target.exists():
        verify_assembled(target, parts)
    else:
        work = target.with_name(target.name + '.assembling')
        total = sum(f['size'] for f in parts)
        offset = work.stat().st_size if work.exists() else 0
        if offset > total:
            raise ValueError(message('Слишком большой временный файл: {0}').format(work))
        require_space(target.parent, total - offset)
        print(message('Сборка GGUF с байта {0} из {1}. Ctrl+C — пауза.').format(offset, total), flush=True)
        with work.open('ab') as dest:
            for f in parts:
                if offset >= f['size']:
                    offset -= f['size']
                    continue
                print(message('Объединение {0}').format(f['rfilename']), flush=True)
                with (target.parent / Path(f['rfilename']).name).open('rb') as src:
                    src.seek(offset)
                    shutil.copyfileobj(src, dest, length=4 * 1024 * 1024)
                offset = 0
            dest.flush()
            os.fsync(dest.fileno())
        print(message('Проверка участков итогового GGUF…'), flush=True)
        verify_assembled(work, parts)
        work.replace(target)
    # Each removed part can now be recovered byte-for-byte from the verified GGUF.
    for f in parts:
        part = target.parent / Path(f['rfilename']).name
        if part.is_file() and part.stat().st_size == f['size']:
            # Existing files may also have been placed here manually.
            verify(part, f)
            part.unlink()
    print(message('Модель собрана и проверена: {0}').format(target), flush=True)


def storage_root(disk):
    root = disk / 'Models'
    legacy = disk / 'Модели'
    return contained(disk, legacy if not root.exists() and legacy.exists() else root)


def file_identity(files):
    return sorted((f['rfilename'], f['size'], f.get('lfs', {}).get('sha256') or f['blobId'])
                  for f in files)


def model_folder(m, disk, canonical=False, reuse_equivalent=True):
    root = storage_root(disk)
    if (not re.fullmatch(r"[0-9]+",m['key']) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}",m['rev'])
            or not re.fullmatch(r"[\w.-]+/[\w.-]+",m['repo']) or any(x in (".","..") for x in m['repo'].split("/"))):
        raise ValueError(message('Некорректный идентификатор модели в очереди'))
    legacy = root / m['repo'] / m['rev'] / ('set-' + m['key'])
    contained(root, legacy)
    suffix = f" [{m['key']} - {m['rev'][:12]}]"
    old_suffix = f" [{m['key']} · {m['rev'][:12]}]"
    purposes = m.get('purposes') or []
    category = next((folder for purpose, folder in MODEL_PURPOSE_FOLDERS.items() if purpose in purposes),
                    MODEL_PURPOSE_FOLDERS['Не указано'])
    name = m['name']
    if any(char.isalpha() and not char.isascii() for char in name):
        name = m['repo'].rsplit('/', 1)[-1]
    unsupported = r'[^A-Za-z0-9_ .()+,=-]+'
    name = re.sub(unsupported, ' ', name).strip(' .-') or 'Model'
    quant = re.sub(r'\([^\x00-\x7f]+\)', '', m['quant'])
    quant = re.sub(unsupported, ' ', quant).strip(' .-')
    label = ' - '.join(filter(None, (name, quant)))[:210].rstrip(' .-')
    destination = root / category / (label + suffix)
    contained(root, destination)
    if canonical or destination.is_dir():
        return destination
    if legacy.is_dir():
        return legacy
    # Resume existing sets after a layout change or a registry edit.
    equivalents = []
    for parent in (root, *(root / folder for folder in MODEL_PURPOSE_FOLDERS.values())):
        if parent.is_dir():
            for child in parent.iterdir():
                if child.name.endswith((suffix, old_suffix)) and child.is_dir():
                    return contained(root, child)
                if child.name.endswith((' - ' + m['rev'][:12] + ']', ' · ' + m['rev'][:12] + ']')):
                    equivalents.append(child)
    if reuse_equivalent:
        equivalents.extend(legacy.parent.glob('set-*'))
        expected_files = None
        for candidate in sorted(equivalents):
            if candidate.is_symlink() or not candidate.is_dir():
                continue
            manifest = contained(root, candidate / '.download-files.json')
            if not manifest.is_file():
                continue
            try:
                data = json.loads(manifest.read_text())
                if data['identity'][:2] != [m['repo'], m['rev']]:
                    continue
                files = data['files']
                if len(files) != m['count'] or sum(f['size'] for f in files) != m['size']:
                    continue
                previous_files = file_identity(files)
            except (ValueError, KeyError, TypeError):
                continue
            if expected_files is None:
                _, expected = metadata(m, m['rev'])
                expected_files = file_identity(expected)
            if previous_files == expected_files:
                return candidate
    return destination



def organize_models(disk, preview=False):
    root = storage_root(disk)
    if not root.is_dir():
        return []
    moved = []
    with (root / '.queue.lock').open('a') as queue_lock:
        fcntl.flock(queue_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for m in catalog().values():
            old = model_folder(m, disk, reuse_equivalent=False)
            dest = model_folder(m, disk, canonical=True)
            legacy = root / m['repo'] / m['rev'] / ('set-' + m['key'])
            if legacy.is_dir() and dest.is_dir():
                raise ValueError(message('Две папки одного комплекта. Обе сохранены: {0} и {1}').format(legacy, dest))
            if old == dest or not old.is_dir():
                continue
            if dest.exists():
                raise ValueError(message('Две папки одного комплекта. Обе сохранены: {0} и {1}').format(old, dest))
            manifest = old / '.download-files.json'
            if not manifest.is_file() or json.loads(manifest.read_text()).get('identity') != [m['repo'],m['rev'],m['patterns']]:
                continue
            if preview:
                moved.append(str(old.relative_to(root)) + " → " + str(dest.relative_to(root)))
                continue
            with (old / '.download.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                dest.parent.mkdir(parents=True, exist_ok=True)
                old.rename(dest)
                moved.append(str(dest))
    return moved


def model_files(m, folder, cache, *, cached_only=False):
    manifest = contained(folder, folder / '.download-files.json')
    identity = [m['repo'], m['rev'], m['patterns']]
    cached = json.loads(manifest.read_text(encoding='utf-8')) if manifest.exists() else {}
    if cached.get('identity') == identity:
        files = cached['files']
    elif cached_only:
        return None
    else:
        _, files = metadata(m, m['rev'])
    seen = set()
    for f in files:
        name = f['rfilename']
        if (not name or Path(name).is_absolute() or any(not part or part in ('.','..') or
                part.startswith('.download') for part in name.split('/')) or name.casefold() in seen):
            raise ValueError(message('Недопустимое или повторяющееся имя файла'))
        if any(part.startswith('.download') or part in ('.queue.lock','.download-queue.json') for part in name.split('/')):
            raise ValueError(message('Имя файла зарезервировано загрузчиком'))
        seen.add(name.casefold())
        sha = f.get("lfs",{}).get("sha256")
        if not (isinstance(sha,str) and re.fullmatch("[0-9a-f]{64}",sha) or
                "lfs" not in f and re.fullmatch("[0-9a-f]{40}",f.get("blobId",""))):
            raise ValueError(message('У файла отсутствует корректная контрольная сумма'))
        path = contained(folder, folder / name)
        contained(folder, partial(path))
        if not isinstance(f['size'], int) or f['size'] < 0:
            raise ValueError(message('Некорректный размер файла'))
        if 'url' in f:
            u = urlsplit(f['url'])
            if u.scheme != 'https' or u.netloc not in ('huggingface.co','modelscope.ai','modelscope.cn','registry.ollama.ai'):
                raise ValueError(message('Неизвестный адрес файла весов'))
    for base in file_groups(files, model=m):
        contained(folder, folder / base)
        contained(folder, folder / (base + '.assembling'))
    if sum(f['size'] for f in files) != m['size'] or len(files) != m['count']:
        raise ValueError(message('Состав файлов расходится с реестром'))
    if (cache and cached.get('identity') != identity and
            not (cached.get('identity', [])[:2] == identity[:2] and
                 file_identity(cached.get('files', [])) == file_identity(files))):
        save_json(manifest, {'identity': identity, 'files': files})
    return files


def package_artifacts(files, model):
    """Return final paths and the pinned files whose digests establish their identity."""
    result = {f['rfilename']: [f] for f in files}
    for base, parts in file_groups(files, model=model).items():
        for f in parts:
            result.pop(f['rfilename'])
        result[base] = parts
    return result


def peer_packages(model, disk, folder):
    root = storage_root(disk)
    rev = model['rev']
    endings = (' - ' + rev[:12] + ']', ' · ' + rev[:12] + ']')
    for parent in (root, *(root / name for name in MODEL_PURPOSE_FOLDERS.values()),
                   root / model['repo'] / rev):
        if not parent.is_dir() or parent.is_symlink():
            continue
        legacy = parent == root / model['repo'] / rev
        for peer in parent.iterdir():
            matches = peer.name.startswith('set-') if legacy else peer.name.endswith(endings)
            if not matches or peer == folder or peer.is_symlink():
                continue
            manifest = peer / '.download-files.json'
            if not manifest.is_file() or manifest.is_symlink():
                continue
            try:
                info = json.loads(manifest.read_text(encoding='utf-8'))
                if info['identity'][:2] == [model['repo'], rev]:
                    yield peer, info
            except (ValueError, OSError, KeyError, TypeError):
                continue


def lm_models_root():
    config = Path.home() / '.lmstudio'
    try:
        settings = json.loads((config / 'settings.json').read_text(encoding='utf-8-sig'))
    except (FileNotFoundError, ValueError):
        settings = {}
    value = settings.get('downloadsFolder') if isinstance(settings, dict) else None
    if isinstance(value, str) and value.strip():
        path = Path(value).expanduser()
        if path.is_absolute():
            return path.resolve()
    return (config / 'models').resolve()


def lm_library(model, disk):
    if model.get('source', 'Hugging Face') not in ('LM Studio', 'Hugging Face'):
        return None
    if not re.fullmatch(r'[\w-][\w.-]*/[\w-][\w.-]*', model['repo']):
        return None
    root = lm_models_root()
    repo = root / model['repo']
    if repo.is_dir() and repo.stat().st_dev == disk.stat().st_dev:
        return repo
    return None


def reusable_files(model, disk, folder, files, peers):
    # Individual raw parts may exist during assembly. A completed assembly can
    # be reused only if its entire ordered sequence of pinned parts matches.
    wanted = package_artifacts(files, model)
    wanted.update({f['rfilename']: [f] for f in files})
    available = {}
    for peer, info in peers:
        try:
            prior = info['files']
            artifacts = package_artifacts(prior, {'patterns':info['identity'][2]})
            artifacts.update({f['rfilename']:[f] for f in prior})
            for name in wanted.keys() & artifacts.keys():
                if name in available or (folder / name).exists() or file_identity(wanted[name]) != file_identity(artifacts[name]):
                    continue
                source = contained(peer, peer / name)
                if source.is_file() and source.stat().st_size == sum(f['size'] for f in wanted[name]):
                    available[name] = source
        except (ValueError, OSError, KeyError, TypeError):
            continue
    external = lm_library(model, disk)
    if external:
        for name, parts in wanted.items():
            if name in available or (folder / name).exists():
                continue
            candidates = [external / name]
            if Path(name).name != name:
                candidates.append(external / Path(name).name)
            expected = sum(f['size'] for f in parts)
            for candidate in candidates:
                try:
                    source = contained(external, candidate)
                    if source.is_file() and source.stat().st_size == expected:
                        available[name] = source
                        break
                except (ValueError, OSError):
                    continue
    for base, parts in file_groups(files, model=model).items():
        if base in available or (folder / base).is_file():
            for f in parts:
                available.pop(f['rfilename'], None)
    return available


def volume_copy_mode(path):
    """Query filesystem capabilities without creating a probe during preview."""
    if sys.platform != 'darwin':
        return 'copy'
    # getattrlist(2), sys/attr.h: ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES.
    attrs = struct.pack('=HH5I', 5, 0, 0, 0x80020000, 0, 0, 0)
    buffer = ctypes.create_string_buffer(36)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.getattrlist(os.fsencode(path), attrs, buffer, len(buffer), 0):
        return 'copy'
    size, *caps = struct.unpack('=9I', buffer.raw)
    if size == 36 and caps[1] & caps[5] & 0x10000:
        return 'clone'
    if size == 36 and caps[0] & caps[4] & 0x04:
        return 'hardlink'
    return 'copy'


def local_file_mode(mode, source, device):
    if source.stat().st_dev != device:
        return 'copy'
    if mode == 'hardlink' and not re.search(r'\.(gguf(?:\.part\d+of\d+)?|safetensors|bin|pt|pth|onnx)$', source.name, re.I):
        # Configs and tokenizers are frequently edited by tools in place.
        return 'copy'
    return mode


def clone_or_copy(source, target, mode):
    if mode == 'hardlink':
        try:
            os.link(source, target)
            return
        except OSError as exc:
            if exc.errno not in (errno.ENOTSUP, errno.EXDEV, errno.EPERM, errno.EMLINK):
                raise
    if mode == 'clone':
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.clonefile(os.fsencode(source), os.fsencode(target), 0) == 0:
            return
        error = ctypes.get_errno()
        if error not in (errno.ENOTSUP, errno.EXDEV, errno.EINVAL, errno.EPERM):
            raise OSError(error, os.strerror(error), str(target))
    require_space(target.parent, source.stat().st_size)
    shutil.copyfile(source, target)


def restore_local_files(model, folder, files, reusable, mode, on_progress):
    done = model['size'] - space_for_model(model, folder, files, reusable)[0]
    device = folder.stat().st_dev
    artifacts = package_artifacts(files, model)
    artifacts.update({f['rfilename']:[f] for f in files})
    restored = {}
    for name, source in reusable.items():
        target = folder / name
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = contained(folder, target.parent / '.download-reuse.tmp')
        tmp.unlink(missing_ok=True)
        try:
            if on_progress:
                on_progress(model, done, 'verify', name)
            clone_or_copy(source, tmp, local_file_mode(mode, source, device))
            parts = artifacts[name]
            if len(parts) == 1 and name == parts[0]['rfilename']:
                verify(tmp, parts[0])
            else:
                verify_assembled(tmp, parts)
            tmp.replace(target)
            restored[name] = file_stamp(target)
            partial(target).unlink(missing_ok=True)
        except (ValueError, FileNotFoundError):
            # Missing or modified peer payload: use the normal verified transfer.
            continue
        finally:
            tmp.unlink(missing_ok=True)
    return restored


def file_stamp(path):
    item = path.stat()
    return [item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns, item.st_nlink]


def verification_record(folder, files, stamps):
    manifest = json.loads((folder / '.download-files.json').read_text(encoding='utf-8'))
    return dict(version=1, identity=manifest['identity'], files=[list(item) for item in file_identity(files)], stamps=stamps)


def integrity_status(folder, model, files):
    marker = contained(folder, folder / '.download-verified.json')
    if not marker.is_file():
        return 'size'
    try:
        cached = json.loads(marker.read_text(encoding='utf-8'))
        if cached['version'] != 1:
            return 'size'
        stamps = {name:file_stamp(contained(folder, folder / name)) for name in package_artifacts(files, model)}
        current = verification_record(folder, files, stamps)
        # Adding a hard link updates ctime without changing the bytes. Inode,
        # size and mtime still have to match for every file in the package.
        previous = cached.pop('stamps')
        if cached != {key:value for key,value in current.items() if key != 'stamps'} or previous.keys() != stamps.keys():
            return 'changed'
        for name, stamp in stamps.items():
            old = previous[name]
            if stamp != old and not (len(old) == 6 and stamp[:4] == old[:4] and stamp[5] != old[5]):
                return 'changed'
        return 'verified'
    except (ValueError, OSError, KeyError, TypeError):
        return 'changed'


def space_for_model(m, folder, files, reusable=()):
    """Bytes still to download, bytes to append during assembly, bytes freed after."""
    merge = released = remaining = 0
    raw, assembled = set(), set()
    for base, parts in file_groups(files, model=m).items():
        names = {f['rfilename'] for f in parts}
        raw.update(names)
        total = sum(f['size'] for f in parts)
        target = folder / base
        if target.exists() or base in reusable:
            if base not in reusable and target.stat().st_size != total:
                raise ValueError(message('Неверный размер собранной модели: ') + str(target))
            assembled.update(names)
        else:
            work = stat_if_present(target.with_name(target.name + '.assembling'))
            offset = work.st_size if work else 0
            if offset > total:
                raise ValueError(message('Неверный размер временной сборки: ') + str(target))
            merge += total - offset
    for f in files:
        name = f['rfilename']
        path = folder / name
        tmp = stat_if_present(partial(path))
        final = stat_if_present(path)
        if final:
            if final.st_size != f['size']:
                raise ValueError(message('Неверный размер файла: ') + str(path))
            if name in raw and final.st_nlink == 1:
                released += min(final.st_size, final.st_blocks * 512)
        elif name not in assembled and name not in reusable:
            missing = f['size'] - (tmp.st_size if tmp else 0)
            if missing < 0:
                raise ValueError(message('Слишком большой частичный файл: ') + str(partial(path)))
            remaining += missing
            if name in raw and (tmp is None or tmp.st_nlink == 1):
                released += missing + (min(tmp.st_size, tmp.st_blocks * 512) if tmp else 0)
    return remaining, merge, released


def payload_budget(model, disk, folder, files, peers=None):
    if peers is None:
        peers = peer_packages(model, disk, folder)
    local = reusable_files(model, disk, folder, files, peers)
    remaining, merge, released = space_for_model(model, folder, files, local)
    # On a non-cloning volume the local files still cost space, but no network bytes.
    copy_bytes = 0
    if local:
        mode, device = volume_copy_mode(disk), disk.stat().st_dev
        copy_bytes = sum(path.stat().st_size for path in local.values() if local_file_mode(mode, path, device) == 'copy')
    return remaining, remaining + merge + copy_bytes, released


def preview_queue(pending, disk, on_row=None, output=print):
    output(message('\nПредпросмотр очереди · {0}').format(storage_root(disk)))
    output(message('Объёмы в десятичных ГБ. Наличие оценено по размерам. Контрольные суммы проверяются при запуске.'))
    output(f"{'№':>3}  {message('Состояние'):<21} {message('На диске¹'):>10} "
           f"{message('Докачать'):>10} {message('Подготовка²'):>10}  {message('Модель')}")
    used = peak = network = 0
    for m in pending:
        folder = model_folder(m, disk)
        raw_candidate = any('.gguf.part' in pat.lower() for pat in m['patterns'])
        peers = list(peer_packages(m, disk, folder))
        if folder.exists() or raw_candidate or peers or lm_library(m, disk):
            files = model_files(m, folder, cache=False)
            remaining, needed, released = payload_budget(m, disk, folder, files, peers)
            merge = needed - remaining
        else:
            needed = remaining = m['size']
            merge = released = 0
        if remaining == m['size']:
            status = message('Скачать')
        elif remaining:
            status = message('Докачать')
        elif merge:
            status = message('Подготовить локально')
        else:
            status = message('Скачано по размеру')
        output(f"{m['key']:>3}  {status:<21} {(m['size']-remaining)/1e9:10.3f} "
              f"{remaining/1e9:10.3f} {merge/1e9:10.3f}  {m['name']}")
        output(message('     Папка: {0}').format(folder))
        if on_row:
            on_row(m, remaining)
        network += remaining
        used += needed
        peak = max(peak, used)
        used -= released
    output(message('¹ Учтены частичные и повторно используемые файлы. ² Место для локальных копий и сборки.'))
    free = shutil.disk_usage(disk).free
    total = sum(m['size'] for m in pending)
    output(message('Очередь: всего {0:.3f} ГБ. Осталось скачать {1:.3f} ГБ. Пиковая потребность в свободном месте {2:.3f} ГБ. Свободно {3:.3f} ГБ.').format(total / 1e9, network / 1e9, peak / 1e9, free / 1e9), flush=True)
    if peak > free:
        output(message('Не хватает {0:.3f} ГБ.').format((peak - free) / 1e9))
    return peak <= free


def download(m, disk, on_progress=None):
    folder = model_folder(m, disk)
    folder.mkdir(parents=True, exist_ok=True)
    with contained(folder, folder / '.download.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        files = model_files(m, folder, cache=True)
        local = reusable_files(m, disk, folder, files, peer_packages(m, disk, folder))
        mode = volume_copy_mode(folder) if local else 'copy'
        restored = restore_local_files(m, folder, files, local, mode, on_progress)
        stamps = dict(restored)
        remaining, merge, _ = space_for_model(m, folder, files)
        require_space(folder, remaining + merge)
        done = m['size'] - remaining
        if on_progress:
            on_progress(m, done, 'prepare', '')
        groups = file_groups(files, model=m)
        finished_parts = {f['rfilename'] for base, parts in groups.items() if (folder / base).exists() for f in parts}
        print(message('{0}\nОсталось скачать {1:.3f} ГБ. Ctrl+C — пауза.').format(folder, remaining / 1e9), flush=True)
        for i, f in enumerate(files, 1):
            if f['rfilename'] in finished_parts:
                continue
            print(f"[{i}/{len(files)}] {f['rfilename']}", flush=True)
            url = f"https://huggingface.co/{m['repo']}/resolve/{m['rev']}/{quote(f['rfilename'])}"
            path = folder / f['rfilename']
            if f['rfilename'] in restored:
                continue
            if on_progress:
                gained = 0
                def report(phase, delta):
                    nonlocal gained
                    if phase == 'network':
                        gained = delta
                    on_progress(m, done + gained, phase, f['rfilename'])
                transfer(path, f, f.get('url', url), report)
                done += gained
            else:
                transfer(path, f, f.get('url', url))
            stamps[f['rfilename']] = file_stamp(path)
        for base, parts in groups.items():
            target = folder / base
            if on_progress:
                on_progress(m, done, "assemble", target.name)
            assemble_mimo(target, parts)
            stamps[base] = file_stamp(target)
            for f in parts:
                stamps.pop(f['rfilename'], None)
        marker = contained(folder, folder / '.download-verified.json')
        save_json(marker, verification_record(folder, files, stamps))
        print(message('Все файлы проверены.'), folder)


def review(m):
    if m.get("resolvedFiles"):
        print("Закреплённый комплект", m["source"], "· для сравнения версий откройте каталог в GUI.")
        return
    if any('::' in p for p in m['patterns']):
        metadata(m, m['rev'])
        print(m['name'], '— закреплённый комплект доступен. Обновляйте по манифесту соответствующей версии движка.')
        return
    revision, files = metadata(m, 'main')
    if revision == m['rev']:
        print(m['name'], "— уже актуальная ревизия.")
        return
    size = sum(f['size'] for f in files)
    print("Новая ревизия. Проверьте состав и карточку перед заменой строки реестра.")
    for f in files:
        print(f['rfilename'], f['size'])
    repo = m['repo']
    print(f"| {m['key']} | {m['name']} | {m['quant']} | {m['roles']} | {size/1e9:.3f} | {size} | "
          f"{len(files)} | [{repo}](https://huggingface.co/{repo}/tree/{revision}) | "
          f"`{' '.join(m['patterns'])}` | {', '.join(m.get('purposes', []))} |")


def choose_models(models):
    list_entries(models)
    answer = input("Номера (например 3,6,15-18) или «все» для набора диска: ").strip().lower()
    if answer in ('все', 'всё', 'all'):
        roles = {'1': 'внешний', '2': 'внутренний', '3': 'HDD'}
        role = input("Какой набор скачать сюда? 1 — внешний SSD, 2 — внутренний SSD, 3 — HDD: ").strip()
        if role not in roles:
            raise ValueError("Неизвестный набор диска")
        return [m for m in models.values() if roles[role] in m['roles'].split(',')]
    keys = []
    for token in re.split(r'[,\s]+', answer):
        match = re.fullmatch(r'(\d+)(?:[-–](\d+))?', token)
        if not match:
            raise ValueError("Введите номера через запятую или диапазон, например 3,6,15-18")
        first, last = int(match[1]), int(match[2] or match[1])
        if last < first or last - first >= len(models):
            raise ValueError("Неверный диапазон " + token)
        for number in range(first, last + 1):
            key = str(number)
            if key not in models:
                raise ValueError("В реестре нет номера " + key)
            if key not in keys:
                keys.append(key)
    return [models[key] for key in keys]


def save_json(path, data):
    import tempfile
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as stream:
        tmp = Path(stream.name)
        try:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise
    try:
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def run_queue(models, disk):
    root = storage_root(disk)
    root.mkdir(exist_ok=True)
    state = root / '.download-queue.json'
    with (root / '.queue.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pending = json.loads(state.read_text(encoding='utf-8')) if state.exists() else []
        if not pending:
            pending = choose_models(models)
            save_json(state, pending)
        while True:
            fits = preview_queue(pending, disk)
            start = "Введите «старт» для запуска, " if fits else ""
            answer = input(start + "«выбор» для замены очереди или Enter для выхода: ").strip().lower()
            if fits and answer == "старт":
                break
            if answer == "выбор":
                pending = choose_models(models)
                save_json(state, pending)
            elif answer in ("", "q"):
                print("Очередь сохранена.")
                return
            else:
                print("Выберите одно из предложенных действий.")
        download_queue(pending, disk, state)


def download_queue(pending, disk, state, on_progress=None):
    while pending:
        m = pending[0]
        if not m.get("downloadStarted"):
            m = dict(m, downloadStarted=True)
            pending = [m] + pending[1:]
            save_json(state, pending)
        print(f"В очереди {len(pending)}. Загружается № {m['key']} · {m['name']}", flush=True)
        if on_progress:
            download(m, disk, on_progress)
        else:
            download(m, disk)
        pending = pending[1:]
        save_json(state, pending)
    print("Очередь завершена.")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--list', action='store_true', help='показать реестр и итоги')
    cli.add_argument('--check', metavar='ID', help='сверить ревизию модели с main')
    args = cli.parse_args()
    models = catalog()
    if args.check:
        review(models[args.check])
        return
    if args.list:
        list_entries(models)
        return
    run_queue(models, choose_disk())


if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\nПауза. Для продолжения выберите ту же папку и подтвердите очередь словом «старт».")
    except BlockingIOError:
        sys.exit("Эта загрузка уже открыта в другом окне.")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"Загрузка остановлена (curl {exc.returncode}). Частичные файлы сохранены.")
    except (OSError, KeyError, ValueError) as exc:
        sys.exit(f"Не удалось продолжить: {exc}")
