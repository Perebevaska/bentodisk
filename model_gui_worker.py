"""JSON events for the native macOS model downloader."""
import collections
from concurrent.futures import ThreadPoolExecutor, as_completed
import fnmatch
import fcntl
import hashlib
from html.parser import HTMLParser
import json
import math
import os
from pathlib import Path
import runpy
import re
import shutil
import signal
import sqlite3
import struct
from urllib.parse import parse_qs, quote, urlencode, urlsplit, unquote
import tempfile
import subprocess
import sys
import time
import threading

core = runpy.run_path(str(Path(__file__).resolve().with_name("Скачать модели.command")))


message_text = core["message"]


def emit(event, **data):
    sys.stdout.write("@@" + json.dumps(dict(event=event, **data), ensure_ascii=False) + "\n")
    sys.stdout.flush()


PURPOSE_TAGS = {
    "Текст и диалог": ("text-generation", "text2text-generation", "chat", "text-to-text", "tools", "thinking"),
    "Код": ("code", "coding", "code-generation", "fill-in-middle"),
    "Анализ изображений": ("image-text-to-text", "visual-question-answering", "vision"),
    "Распознавание текста (OCR)": ("ocr", "ocr-recognition", "optical-character-recognition"),
    "Эмбеддинги": ("sentence-similarity", "feature-extraction", "sentence-embedding", "text-embedding", "embedding"),
    "Реранжирование": ("reranker", "reranking", "text-ranking"),
    "Генерация изображений": ("text-to-image", "text-to-image-synthesis", "image-generation"),
    "Редактирование изображений": ("image-to-image", "image-editing"),
    "Управление генерацией": ("controlnet",),
    "Распознавание речи": ("automatic-speech-recognition", "asr", "speech-recognition"),
    "Синтез речи": ("text-to-speech", "tts"),
    "Генерация видео": ("text-to-video", "video-generation", "image-to-video"),
}


def model_purposes(tags):
    normalized = {tag.strip().casefold() for tag in tags if isinstance(tag, str)}
    return [label for label, aliases in PURPOSE_TAGS.items() if normalized.intersection(aliases)]


def hf_purposes(data):
    return model_purposes([data.get("pipeline_tag")] + (data.get("tags") or []))


def search_models(req):
    query = req["query"].strip()
    author = req.get("author","").strip().lstrip("@")
    sort = req.get("sort", "downloads")
    params = {"limit": 25, "sort": {"downloads":"downloads","likes":"likes","trending":"trendingScore"}[sort],
              "direction": -1, "expand": ["downloads","likes","trendingScore","pipeline_tag","tags"]}
    if query:
        params["search"] = query
    if author:
        params["author"] = hf_author(safe_id(author, NAME))
    filters = []
    if req.get("purpose") in PURPOSE_TAGS:
        filters.append(PURPOSE_TAGS[req["purpose"]][0])
    if req.get("format") in ("gguf", "mlx"):
        filters.append(req["format"])
    if filters:
        params["filter"] = filters
    if req.get("cursor"):
        params["cursor"] = req["cursor"]
    url = "https://huggingface.co/api/models?" + urlencode(params, doseq=True)
    with tempfile.TemporaryDirectory() as tmp:
        headers = Path(tmp) / "headers"
        args = [core["CURL"], "-fsSL", "--connect-timeout", "10", "--max-time", "30",
                "--dump-header", str(headers), "--write-out", "\n%{http_code}", url]
        result = subprocess.run(args, stdout=subprocess.PIPE)
        body, _, status = result.stdout.rpartition(b"\n")
        if result.returncode:
            if status.strip() not in (b"", b"000"):
                raise ValueError(message_text('Ошибка поиска Hugging Face (HTTP ') + status.decode() + ")")
            raise ValueError(message_text('Не удалось подключиться к Hugging Face. Повторите поиск.'))
        items = json.loads(body)
        match = re.search(r'<([^>]+)>;\s*rel="next"', headers.read_text(encoding="latin1"), re.I)
    cursor = parse_qs(urlsplit(match[1]).query).get("cursor", [None])[0] if match else None
    return {"results": [dict(id=item["id"], downloads=item.get("downloads"), likes=item.get("likes"),
                              trending=item.get("trendingScore"), purposes=hf_purposes(item))
                        for item in items], "cursor": cursor}


def hf_author(author):
    # The repository search folds case, while the author parameter requires the exact namespace.
    params = urlencode({"search": author + "/", "limit": 10})
    models = json.loads(fetch_catalog("https://huggingface.co/api/models?" + params))
    for model in models:
        owner, _, _ = model["id"].partition("/")
        if owner.casefold() == author.casefold():
            return owner
    return author


def fetch_catalog(url, payload=None, timeout=45, max_bytes=None):
    args = [core["CURL"], "-fsSL", "--connect-timeout", str(min(12,timeout)), "--max-time", str(timeout)]
    if max_bytes is not None:
        args += ["--max-filesize", str(max(1,max_bytes))]
    if payload is not None:
        args += ["-X", "PUT", "-H", "Content-Type: application/json", "--data-binary", json.dumps(payload)]
    result = subprocess.run(args + ["--write-out", "\n%{http_code}", url], stdout=subprocess.PIPE)
    body, _, status = result.stdout.rpartition(b"\n")
    if result.returncode:
        raise ValueError(message_text('Каталог недоступен (HTTP %s, curl %s)') % (status.decode(), result.returncode))
    return body


def ms_request(path, payload=None, timeout=45):
    errors = []
    for host in ("https://modelscope.ai", "https://modelscope.cn"):
        try:
            reply = json.loads(fetch_catalog(host + path, payload, timeout=timeout))
            if reply.get("Success") and reply.get("Data") is not None:
                return host, reply["Data"]
            raise ValueError(reply.get("Message") or message_text('Не удалось получить список'))
        except (ValueError, OSError) as error:
            errors.append(str(error))
    raise ValueError("ModelScope: " + " / ".join(errors))


def safe_id(value, pattern):
    if not re.fullmatch(pattern, value) or any(s in ("", ".", "..") for s in value.split("/")):
        raise ValueError(message_text('Некорректный идентификатор модели'))
    return value


NAME = r"[\w-][\w.-]*"
REPO = NAME + "/" + NAME


class Links(HTMLParser):
    def __init__(self, page):
        super().__init__(convert_charrefs=True)
        self.urls = {}
        self.active = None
        self.feed(page.decode())

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.active = dict(attrs).get("href", "")
            self.urls.setdefault(self.active, [])

    def handle_data(self, text):
        if self.active is not None:
            self.urls[self.active].append(text.strip())

    def handle_endtag(self, tag):
        if tag == "a":
            self.active = None


def hits(values, kind, cursor=None):
    return {"results": [dict(id=k, kind=kind) for k in dict.fromkeys(values)], "cursor":cursor}


def metric(text, label):
    match = re.search(r"(?:^|\s)([\d,.]+)\s*([KMB]?)\s+" + label, text, re.I)
    if match:
        return round(float(match[1].replace(",", "")) * {"":1,"K":1e3,"M":1e6,"B":1e9}[match[2].upper()])
    return None


def platform_search(req):
    provider, query = req["source"], req["query"].strip()
    author = req.get("author","").strip().lstrip("@")
    if author:
        author = safe_id(author, NAME).casefold()
    sort = req.get("sort", "downloads")
    if sort == "trending" or (sort == "likes" and provider == "Ollama Library"):
        raise ValueError(message_text('Каталог не публикует выбранный рейтинг'))
    purpose = req.get("purpose")
    if provider == "ModelScope":
        page = max(1, int(req.get("cursor") or 1))
        params = {"PageSize":25,"PageNumber":page, "SortBy": "StarsCount" if sort == "likes" else "DownloadsCount"}
        if query:
            params["Name"] = query
        if author:
            params["Path"] = author
        _, data = ms_request("/api/v1/models/", params)
        results = []
        models = data["Models"]
        if models is None and data.get("TotalCount") == 0:
            models = []
        if not isinstance(models, list):
            raise ValueError(message_text('Некорректный ответ каталога'))
        for model in models:
            if author and model["Path"].casefold() != author:
                continue
            tags = (model.get("Tags") or []) + [task["Name"] for task in (model.get("Tasks") or [])]
            purposes = model_purposes(tags)
            if not purpose or purpose in purposes:
                results.append(dict(id=model["Path"]+"/"+model["Name"], downloads=model.get("Downloads"), likes=model.get("Stars"),
                                    kind="ms", purposes=purposes))
        results.sort(key=lambda hit: hit.get(sort) or 0, reverse=True)
        return dict(results=results,cursor=str(page+1) if page*25 < data["TotalCount"] else None)
    if provider == "Ollama Library":
        if author and author != "library":
            url = "https://ollama.com/" + author
            pattern = "/" + re.escape(author) + "/" + NAME
        else:
            url = ("https://ollama.com/search?" + urlencode({"q":query,"o":"popular"}) if query else "https://ollama.com/library")
            pattern = "/library/" + NAME
        try:
            links = Links(fetch_catalog(url)).urls
        except ValueError as error:
            if author and author != "library" and "(HTTP 404," in str(error):
                return hits([], "ollama")
            raise
        results = []
        for href, labels in links.items():
            if not re.fullmatch(pattern, href, re.I):
                continue
            if author and author != "library" and query.casefold() not in href[1:].casefold():
                continue
            purposes = model_purposes(labels)
            if not purpose or purpose in purposes:
                text = " ".join(labels)
                pulls = metric(text, r"pulls") or metric(text, r"(?=\d+\s+tags)")
                results.append(dict(id=href[1:], kind="ollama", purposes=purposes, downloads=pulls))
        results.sort(key=lambda hit: hit["downloads"] or 0, reverse=True)
        return dict(results=results,cursor=None)
    if provider == "LM Studio":
        links = Links(fetch_catalog("https://lmstudio.ai/models")).urls
        # Catalog cards link to families; individual releases list the actual downloadable repositories.
        words = re.findall(r"[\w.]+",query.casefold())
        matches = [u[8:] for u, text in links.items() if re.fullmatch("/models/"+NAME,u) and
                   all(w in (u[8:] + " " + " ".join(text)).casefold() for w in words)]
        stats = {family: {"downloads": metric(" ".join(links.get("/models/"+family, [])), "downloads"),
                          "likes": metric(" ".join(links.get("/models/"+family, [])), "stars")} for family in matches}
        matches.sort(key=lambda family: stats[family].get(sort) or 0, reverse=True)
        if re.fullmatch(REPO,query):
            matches.insert(0, query)
        if author or purpose or (query and req.get("resolveRepositories")):
            # Resolve the actual publisher of the weights from official catalog cards.
            start = max(0,int(req.get("cursor") or 0))
            families = matches[start:start+5]
            def family_children(key):
                if key == query and re.fullmatch(REPO, query):
                    try:
                        return lm_children(key, direct=True)
                    except ValueError as error:
                        if "(HTTP 404," in str(error):
                            return "lm", []
                        raise
                return lm_children(key)
            with ThreadPoolExecutor(max_workers=4) as pool:
                children = list(pool.map(family_children,families))
                releases = list(dict.fromkeys(v for kind,items in children if kind=="lm" for v in items))
                children.extend(pool.map(lm_children,releases))
            repos = list(dict.fromkeys(r for kind, items in children if kind == "hf" for r in items
                                      if not author or r.split("/",1)[0].casefold() == author))
            if purpose:
                with ThreadPoolExecutor(max_workers=4) as pool:
                    labels = list(pool.map(lm_repo_purposes, repos))
                repos = [repo for repo, purposes in zip(repos, labels) if purpose in purposes]
            return hits(repos,"hf",str(start+5) if start+5 < len(matches) else None)
        return dict(results=[dict(id=key,kind="lm",**stats.get(key, {})) for key in matches], cursor=None)
    raise ValueError(message_text('Неизвестный каталог'))


def lm_repo_purposes(repo):
    safe_id(repo, REPO)
    try:
        encoded = urlencode({"expand": ["pipeline_tag", "tags"]}, doseq=True)
        return hf_purposes(json.loads(fetch_catalog("https://huggingface.co/api/models/"+repo+"?"+encoded)))
    except ValueError as error:
        if "(HTTP 404," in str(error) or "(HTTP 401," in str(error):
            return []
        raise


def browse_platform(req):
    key = req["id"]
    if req["kind"] == "ollama":
        safe_id(key, REPO)
        urls = Links(fetch_catalog("https://ollama.com/"+key+"/tags")).urls
        return hits([u[1:] for u in urls if re.fullmatch("/"+re.escape(key)+":"+NAME,u)
                     and not u.endswith("-cloud")], "tag")
    kind, values = lm_children(key, direct=req["kind"] == "lm-page")
    if not values:
        raise ValueError(message_text('В этой карточке LM Studio нет локальных весов для скачивания.'))
    return hits(values,kind)


def lm_children(key, direct=False):
    safe_id(key, NAME+"(?:/"+NAME+")?")
    path = "/" if direct else "/models/"
    urls = Links(fetch_catalog("https://lmstudio.ai"+path+key)).urls
    repos = [u.split("huggingface.co/")[1] for u in urls if re.fullmatch("https://huggingface[.]co/"+REPO+"/?",u.rstrip("/"))]
    if repos:
        return "hf", [r.rstrip("/") for r in repos]
    variants = [u[8:] for u in urls if re.fullmatch("/models/"+REPO,u) and u[8:] != key]
    return "lm",variants


def ms_manifest(reference, timeout=45):
    repo, _, revision = reference.partition("@")
    safe_id(repo, REPO)
    revision = safe_id(revision or "master", NAME)
    path = "/api/v1/models/"+repo+"/repo"
    host, data = ms_request(path+"/files?"+urlencode({"Revision":revision,"Recursive":"true"}), timeout=timeout)
    prefix = host + path
    rows = data["Files"]
    specs = {}
    for row in rows:
        if row["Type"] != "blob":
            continue
        name = row["Path"]
        sha = safe_id(row["Sha256"],r"[0-9a-f]{64}")
        commit = safe_id(row["Revision"],r"[0-9a-f]{40}")
        specs[name] = dict(rfilename=name,size=row["Size"],lfs={"sha256":sha},
                           url=prefix+"?"+urlencode({"Revision":commit,"FilePath":name}))
    snapshot = hashlib.sha256(json.dumps({n:s["lfs"]["sha256"] for n,s in specs.items()},sort_keys=True).encode()).hexdigest()
    return snapshot, specs


def payload_identities(specs):
    identities = {}
    for f in specs:
        digest = (f.get("lfs") or {}).get("sha256") or f.get("blobId")
        if digest:
            identities[f["rfilename"]] = dict(size=f["size"], digest=digest)
    return identities


def ms_plan(reference, timeout=45):
    snapshot, specs = ms_manifest(reference, timeout)
    plan = file_options(reference.partition("@")[0],snapshot,{n:f["size"] for n,f in specs.items()})
    plan["payloads"] = payload_identities(specs.values())
    return plan, specs


def ollama_plan(ref):
    safe_id(ref,REPO+":"+NAME)
    repo,tag = ref.split(":")
    base = "https://registry.ollama.ai/v2/"+repo
    manifest = fetch_catalog(base+"/manifests/"+tag)
    revision = hashlib.sha256(manifest).hexdigest()
    data = json.loads(manifest)
    specs = {}
    def blob_url(blob):
        return base+"/blobs/"+safe_id(blob["digest"],r"sha256:[a-f0-9]{64}")
    config = json.loads(fetch_catalog(blob_url(data["config"])))
    if not any(v.get("mediaType")=="application/vnd.ollama.image.model" for v in data["layers"]):
        raise ValueError(message_text('Для этого тега не опубликованы локальные веса'))
    for blob in [data["config"]]+data["layers"]:
        url = blob_url(blob)
        name = "blobs/"+blob["digest"].replace(":","-")
        specs[name] = dict(rfilename=name,size=blob["size"],lfs={"sha256":blob["digest"][7:]},url=url)
    name = "manifests/registry.ollama.ai/"+repo+"/"+tag
    specs[name] = dict(rfilename=name,size=len(manifest),lfs={"sha256":revision},inline=manifest.decode())
    option = dict(label=tag+" · "+str(config.get("file_type") or config.get("model_format") or "Ollama"),
                  files=sorted(specs),size=sum(s["size"] for s in specs.values()))
    return dict(repo=repo,rev=revision,options=[option],preferred=0,extras=[], payloads=payload_identities(specs.values())), specs


def inspect_link(link):
    url = urlsplit(link.strip())
    if url.scheme != "https" or url.netloc != "huggingface.co":
        raise ValueError(message_text('Вставьте HTTPS-ссылку на модель с huggingface.co'))
    parts = [unquote(p) for p in url.path.strip("/").split("/")]
    if len(parts) < 2 or not all(re.fullmatch(r"[\w-][\w.-]*", p) for p in parts[:2]) or parts[0] in ("datasets", "spaces"):
        raise ValueError(message_text('Нужна ссылка на репозиторий модели'))
    revision, focus = "main", ""
    if len(parts) > 2:
        if len(parts) < 4 or parts[2] not in ("tree", "blob", "resolve") or not re.fullmatch(r"[\w.-]+", parts[3]):
            raise ValueError(message_text('Откройте страницу модели или её файлов'))
        revision, focus = parts[3], "/".join(parts[4:])
    repo = "/".join(parts[:2])
    data = core["repo_metadata"](repo, revision)
    files = {s["rfilename"]: s["size"] for s in data["siblings"]}
    plan = file_options(repo,data["sha"],files,focus)
    plan["payloads"] = payload_identities(data["siblings"])
    plan["purposes"] = hf_purposes(data)
    return plan


def projector_file(name):
    return ("mmproj" in Path(name).name.lower() or
            any(p.lower() in ("mmproj", "projector", "projectors") for p in Path(name).parts[:-1]))


def gguf_group(name):
    return re.sub(r"-\d{5}-of-\d{5}(?=\.gguf$)|\.part\d+of\d+$", "", name, flags=re.I)


def file_options(repo, revision, files, focus=""):
    if any(n.startswith("/") or ".." in n.split("/") or any(p.startswith(".download") for p in n.split("/")) for n in files):
        raise ValueError(message_text('Репозиторий содержит небезопасное имя файла'))
    groups = {}
    projector_groups = {}
    for n in sorted(files):
        if not re.search(r"\.gguf(?:\.part\d+of\d+)?$", n, re.I):
            continue
        basename = Path(n).name.lower()
        if projector_file(n):
            projector_groups.setdefault(gguf_group(n), []).append(n)
            continue
        if basename.startswith(("mtp-", "imatrix-", "dspark-")):
            continue
        groups.setdefault(gguf_group(n), []).append(n)
    extras = []
    for label, parts in projector_groups.items():
        try:
            core["file_groups"]([dict(rfilename=n) for n in parts])
        except ValueError:
            continue
        item = dict(name=label, size=sum(files[n] for n in parts))
        if parts != [label]:
            item["files"] = parts
        extras.append(item)
    projectors = {n for item in extras for n in item.get("files", [item["name"]])}
    # MLX / Transformers / Diffusers snapshots often include shared tokenizers and encoders.
    # Select quant-specific subtrees only when the repository labels them explicitly.
    quant_root = re.compile(r"(?:.*[-_])?(?:[2-8](?:bit|bits)(?:[-_].*)?|bf16|fp16|fp32|int[248])$", re.I)
    safes = [n for n in files if n.endswith((".safetensors", ".bin", ".pt", ".pth", ".onnx"))]
    roots = sorted({n.split("/")[0] for n in safes if "/" in n and quant_root.fullmatch(n.split("/")[0])})
    ggufs = {n for n in files if ".gguf" in n.lower()}
    if roots:
        shared = [n for n in files if n.split("/")[0] not in roots and n not in ggufs]
        for root in roots:
            groups[root] = shared + [n for n in files if n.startswith(root + "/") and n not in ggufs]
    elif safes:
        label = "Исходные веса и конфигурации" if ggufs else "Полный репозиторий"
        precision = re.search(r"(?:^|[-_.])([2-8]bit|bf16|fp16|int[248])(?:$|[-_.])", repo.split("/")[-1], re.I)
        if precision:
            label += " · " + precision[1]
        groups[label] = [n for n in files if n not in ggufs]
    options = [dict(label=k, files=sorted(v), size=sum(files[n] for n in v)) for k,v in groups.items() if v]
    complete = []
    for option in options:
        try:
            core["file_groups"]([dict(rfilename=name) for name in option["files"]])
        except ValueError:
            continue
        if any(n.endswith(".safetensors") for n in option["files"]):
            option["fileSizes"] = {n:files[n] for n in option["files"] if payload_file(n)}
        complete.append(option)
    if options and not complete:
        raise ValueError(message_text('Нет полного комплекта: отсутствуют части модели'))
    options = complete
    if not options:
        raise ValueError(message_text('Подходящих файлов модели не найдено'))
    default = next((i for i, o in enumerate(options) if re.search(r"(?:^|[-_.])Q4_K_M[.]gguf$", o["label"], re.I)), 0)
    preferred = next((i for i,o in enumerate(options) if focus and any(n == focus or n.startswith(focus+"/") for n in o["files"])), default)
    # Resolve pinned catalog entries against the listing already fetched for this revision.
    by_files = {tuple(o["files"]):o for o in options}
    for m in core["catalog"]().values():
        if (m["repo"], m["rev"]) != (repo, revision):
            continue
        if not m.get("personal") and any("::" in pattern for pattern in m["patterns"]):
            _, recipe_files = core["metadata"](m, revision)
            if len(recipe_files) == m["count"] and sum(f["size"] for f in recipe_files) == m["size"]:
                options.append(dict(label=m["quant"], files=sorted(f["rfilename"] for f in recipe_files),
                                    size=m["size"], keys=[m["key"]], recipeKey=m["key"]))
            continue
        chosen = (set(m["patterns"]) if m.get("personal") else
                  {n for n in files if any(fnmatch.fnmatchcase(n, pat) for pat in m["patterns"])})
        if len(chosen) != m["count"] or not chosen.issubset(files) or sum(files[n] for n in chosen) != m["size"]:
            continue
        option = by_files.get(tuple(sorted(chosen.difference(projectors))))
        if option is not None:
            option.setdefault("keys", []).append(m["key"])
    return dict(repo=repo, rev=revision, options=options, preferred=preferred,
                extras=extras)


def matching_model(catalog, plan, names, size):
    wanted = sorted(names)
    for m in catalog.values():
        if (m["repo"],m["rev"],m["size"],m["count"]) != (plan["repo"],plan["rev"],size,len(names)):
            continue
        if sorted(m["patterns"]) == wanted:
            return m
        if not m.get("personal"):
            _, files = core["metadata"](m, m["rev"])
            if sorted(f["rfilename"] for f in files) == wanted:
                return m
    return None


def register_model(req):
    # Re-read the pinned manifest so a moved branch cannot change the confirmed selection.
    source = req.get("source","Hugging Face")
    specs = {}
    if source in ("ModelScope","Ollama Library"):
        plan, specs = (ms_plan if source=="ModelScope" else ollama_plan)(req["reference"])
        if plan["rev"] != req["revision"]:
            raise ValueError(message_text('Публикация изменилась. Откройте модель повторно.'))
    else:
        plan = inspect_link(req["pinned"])
    choice = next((o for o in plan["options"] if o["label"] == req["variant"] and
                   o.get("recipeKey") == req.get("recipeKey")), None)
    if choice is None:
        raise ValueError(message_text("Вариант недоступен"))
    if choice.get("recipeKey"):
        recipe = core["catalog"]()[choice["recipeKey"]]
        if (req["revision"] != recipe["rev"] or req["size"] != recipe["size"] or req["extras"] or
                plan["repo"] != recipe["repo"]):
            raise ValueError(message_text("Состав или размер изменился. Обновите предпросмотр."))
        return recipe
    names, size = list(choice["files"]), choice["size"]
    for f in plan["extras"]:
        if f["name"] in req["extras"]:
            names.extend(f.get("files", [f["name"]]))
            size += f["size"]
    if not size or size != req["size"]:
        raise ValueError(message_text('Состав или размер изменился. Обновите предпросмотр.'))
    personal = core["PERSONAL"]
    personal.parent.mkdir(parents=True, exist_ok=True)
    with personal.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        catalog = core["catalog"]()
        existing = matching_model(catalog, plan, names, size)
        if existing:
            if existing.get("personal") and "purposes" in req and existing.get("purposes") != req["purposes"]:
                existing["purposes"] = req["purposes"]
                core["save_json"](personal,[m for m in catalog.values() if m.get("personal")])
            return existing
        key = str(max([999] + [int(k) for k in catalog]) + 1)
        model = dict(key=key, name=plan["repo"].split("/")[-1], quant=choice["label"], roles="личная",
                     personal=True, repo=plan["repo"], rev=plan["rev"], size=size,
                     count=len(names), patterns=sorted(names))
        model["source"] = source
        model["purposes"] = req.get("purposes",plan.get("purposes",[]))
        if specs:
            model["resolvedFiles"] = [specs[n] for n in sorted(names)]
        core["save_json"](personal,[m for m in catalog.values() if m.get("personal")] + [model])
        return model


CATALOGS = ("Hugging Face", "ModelScope", "LM Studio", "Ollama Library")


def search_catalog(req):
    return search_models(req) if req["source"] == "Hugging Face" else platform_search(req)


def bundle_fingerprint(files):
    entries = []
    has_weights = False
    for name, size, sha in files:
        if not re.fullmatch(r"[0-9a-f]{64}", sha or ""):
            return None
        if re.search(r"\.gguf(?:\.part\d+of\d+)?$", name, re.I):
            # GGUF data embeds the model and quantization. Keep distinct roles and raw part order.
            basename = name.rsplit("/", 1)[-1].lower()
            role = next((role for role in ("mmproj", "dspark", "mtp", "imatrix") if role in basename), "weights")
            split = re.search(r"(?:-\d{5}-of-\d{5}\.gguf|\.part\d+of\d+)$", basename)
            path_key = name if split else role
            has_weights |= role == "weights"
        else:
            path_key = name
            has_weights |= re.search(r"\.(safetensors|bin|pt|pth|onnx)$", name, re.I) is not None
        entries.append((path_key, size, sha))
    if not has_weights:
        return None
    return hashlib.sha256(json.dumps(sorted(entries), ensure_ascii=False).encode()).hexdigest()


def payload_file(name):
    basename = name.rsplit("/", 1)[-1].lower()
    return basename not in (".gitattributes", ".gitignore") and not re.fullmatch(
        r"(?:readme(?:[._-][a-z]{2,8})?|license|licence|notice)(?:\.(?:md|txt|rst))?", basename
    )


def catalog_manifest(key):
    source, repo = key
    if source == "ms":
        revision, files = ms_manifest(repo, timeout=8)
    else:
        safe_id(repo, REPO)
        data = json.loads(fetch_catalog(f"https://huggingface.co/api/models/{repo}/revision/main?blobs=true", timeout=8))
        revision = safe_id(data["sha"], r"[a-f0-9]{40}")
        files = {f["rfilename"]:f for f in data["siblings"]}
    return revision, {n:f for n,f in files.items() if payload_file(n)}


def manifest_fingerprint(key, revision, files):
    source, repo = key
    small = [f for f in files.values() if not f.get("lfs")]
    if len(small) > 12 or sum(f["size"] for f in small) > 8*1024**2:
        return None
    hashes = []
    deadline = time.monotonic() + 10
    for name, f in files.items():
        if source == "ms" and ms_catalog_descriptor(f):
            continue
        sha = f.get("lfs", {}).get("sha256")
        if not sha:
            url = f"https://huggingface.co/{repo}/resolve/{revision}/{quote(name)}"
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            content = fetch_catalog(url, timeout=min(5, remaining), max_bytes=f["size"])
            if len(content) != f["size"]:
                return None
            sha = hashlib.sha256(content).hexdigest()
        hashes.append((name, f["size"], sha))
    return bundle_fingerprint(hashes)


def cached_fingerprint(key, revision, files):
    # Only immutable snapshots are cached. Cache failures never hide catalog results.
    cache = Path.home() / "Library/Caches/ModelDownloader/fingerprints.sqlite3"
    db = None
    fingerprint = None
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(str(cache), timeout=1)
        db.execute("CREATE TABLE IF NOT EXISTS bundles (source TEXT, repo TEXT, rev TEXT, hash TEXT, PRIMARY KEY(source,repo,rev))")
        row = db.execute("SELECT hash FROM bundles WHERE source=? AND repo=? AND rev=?", (*key,revision)).fetchone()
        if row:
            return row[0]
    except (OSError, sqlite3.Error):
        if db:
            db.close()
        db = None
    try:
        fingerprint = manifest_fingerprint(key, revision, files)
        if db and fingerprint:
            with db:
                db.execute("INSERT OR REPLACE INTO bundles VALUES (?,?,?,?)", (*key,revision,fingerprint))
    except sqlite3.Error:
        pass
    finally:
        if db:
            db.close()
    return fingerprint


def ms_catalog_descriptor(file):
    if file["rfilename"] != "configuration.json" or file["size"] > 1024:
        return False
    content = fetch_catalog(file["url"],timeout=5,max_bytes=file["size"])
    if len(content) != file["size"] or hashlib.sha256(content).hexdigest() != file["lfs"]["sha256"]:
        return False
    data = json.loads(content)
    return isinstance(data,dict) and data.keys() == {"framework","task"} and all(
        isinstance(value,str) for value in data.values()
    )


def add_bundle_identities(results):
    def key(hit):
        if hit["source"] == "ModelScope":
            return ("ms", hit["id"])
        if hit["source"] in ("Hugging Face", "LM Studio") and hit.get("kind") not in ("lm", "lm-page"):
            return ("hf", hit["id"])
        return None

    sources = collections.defaultdict(set)
    for hit in results:
        entry = key(hit)
        if entry:
            sources[entry].add(hit["source"])
    if len(set().union(*sources.values())) < 2:
        return results

    def listing(entry):
        try:
            return catalog_manifest(entry)
        except (ValueError, OSError, KeyError, TypeError):
            return None

    def identity(entry):
        try:
            revision, files = manifests[entry]
            fingerprint = cached_fingerprint(entry, revision, files)
            if fingerprint:
                result = dict(fingerprint=fingerprint)
                if entry[0] == "ms":
                    result["snapshot"] = revision
                else:
                    result["url"] = f"https://huggingface.co/{entry[1]}/tree/{revision}"
                return result
        except (ValueError, OSError, KeyError, TypeError):
            pass
        return {}

    with ThreadPoolExecutor(max_workers=8) as pool:
        manifests = dict(zip(sources, pool.map(listing, sources)))
        comparable = collections.defaultdict(list)
        for entry, manifest in manifests.items():
            if manifest:
                sizes = tuple(sorted(f["size"] for n,f in manifest[1].items()
                                     if re.search(r"\.(gguf(?:\.part\d+of\d+)?|safetensors|bin|pt|pth|onnx)$", n, re.I)))
                if sizes:
                    comparable[sizes].append(entry)
        candidates = [entry for bucket in comparable.values()
                      if len(set().union(*(sources[k] for k in bucket))) > 1 for entry in bucket]
        by_key = dict(zip(candidates, pool.map(identity, candidates)))
    return [dict(hit, **by_key.get(key(hit),{})) for hit in results]


def search_all_catalogs(req, on_page=None):
    supplied_cursor = req.get("cursor")
    cursors = json.loads(supplied_cursor) if supplied_cursor else dict.fromkeys(CATALOGS, "")
    results, next_cursors, warnings = [], {}, []

    def search(source):
        page = search_catalog(dict(req, source=source, cursor=cursors[source], resolveRepositories=True))
        if not isinstance(page.get("results"), list):
            raise ValueError(message_text("Некорректный ответ каталога"))
        rows = []
        for hit in page["results"]:
            if not isinstance(hit, dict) or not isinstance(hit.get("id"), str):
                raise ValueError(message_text("Некорректный ответ каталога"))
            rows.append(dict(hit, source=source))
        return rows, page["cursor"]

    with ThreadPoolExecutor(max_workers=len(CATALOGS)) as pool:
        searches = {pool.submit(search, source):source for source in CATALOGS if source in cursors}
        for job in as_completed(searches):
            source = searches[job]
            try:
                rows, cursor = job.result()
                results.extend(rows)
                if cursor:
                    next_cursors[source] = cursor
            except (ValueError, OSError, TypeError, KeyError, AttributeError) as error:
                warnings.append(f"{source}: {error}")
            if on_page:
                on_page(dict(results=list(results), cursor=None, warnings=list(warnings), final=False))
    return dict(results=add_bundle_identities(results) if req["query"].strip() else results,
                cursor=json.dumps(next_cursors) if next_cursors else None, warnings=warnings)


def link_target(link):
    url = urlsplit(link.strip())
    if url.scheme != "https" or not url.netloc:
        raise ValueError(message_text('Вставьте HTTPS-ссылку на страницу модели'))
    host = url.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    parts = [unquote(part) for part in url.path.strip("/").split("/")]
    if host == "huggingface.co":
        return dict(id=safe_id("/".join(parts[:2]), REPO), source="Hugging Face", kind="hf", url=url._replace(netloc=host).geturl())
    if host in ("modelscope.ai", "modelscope.cn"):
        if parts[0] != "models" or len(parts) < 3:
            raise ValueError(message_text('Нужна ссылка ModelScope вида /models/автор/модель'))
        repo = safe_id("/".join(parts[1:3]), REPO)
        revision = parse_qs(url.query).get("Revision", parse_qs(url.query).get("revision", [""]))[0]
        if len(parts) >= 5 and parts[3] in ("tree", "blob", "resolve"):
            revision = parts[4]
        return dict(id=repo+("@"+safe_id(revision,NAME) if revision else ""),source="ModelScope",kind="ms")
    if host == "lmstudio.ai":
        if parts[0] == "models":
            return dict(id=safe_id("/".join(parts[1:]), NAME+"(?:/"+NAME+")?"),source="LM Studio",kind="lm")
        if len(parts) >= 2 and (len(parts) == 2 or parts[2] in ("files","readme")):
            return dict(id=safe_id("/".join(parts[:2]), REPO),source="LM Studio",kind="lm-page")
        raise ValueError(message_text('Нужна ссылка на страницу модели LM Studio'))
    if host in ("ollama.com", "ollama.ai"):
        if len(parts) == 1:
            parts.insert(0,"library")
        if len(parts) not in (2,3) or (len(parts) == 3 and parts[2] not in ("tags","blobs")):
            raise ValueError(message_text('Нужна ссылка на модель или тег Ollama'))
        reference = "/".join(parts[:2])
        if ":" in reference:
            return dict(id=safe_id(reference,REPO+":"+NAME),source="Ollama Library",kind="tag")
        return dict(id=safe_id(reference,REPO),source="Ollama Library",kind="ollama")
    raise ValueError(message_text('Поддерживаются ссылки Hugging Face, ModelScope, LM Studio и Ollama'))


def preview_budget(req, model, disk, folder):
    # The browser sends identities from its pinned listing. They are used only for
    # estimates; the download engine always resolves and verifies its own inputs.
    if req.get("recipeKey"):
        files = core["model_files"](model, folder, cache=False)
    else:
        identities = req.get("payloads", {})
        files = []
        for name in req["files"]:
            spec = identities.get(name)
            if not spec:
                return {}
            size, digest = spec["size"], spec["digest"]
            if (not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", digest) or
                    type(size) != int or size < 0 or Path(name).is_absolute() or ".." in Path(name).parts):
                return {}
            hash_field = dict(lfs={"sha256":digest}) if len(digest) == 64 else dict(blobId=digest)
            files.append(dict(rfilename=name, size=size, **hash_field))
    if sum(f["size"] for f in files) != req["size"]:
        return {}
    remaining, needed, _ = core["payload_budget"](model, disk, folder, files)
    return dict(remainingBytes=remaining, requiredBytes=needed)


def import_request():
    req = json.load(sys.stdin)
    if req["action"] == "search":
        req.setdefault("source", "Hugging Face")
        if req["source"] == "Все каталоги":
            return search_all_catalogs(req)
        page = search_catalog(req)
        page["results"] = [dict(hit,source=req["source"]) for hit in page["results"]]
        return page
    if req["action"] == "browse":
        page = browse_platform(req)
        if req.get("source"):
            page["results"] = [dict(hit, source=req["source"]) for hit in page["results"]]
        return page
    if req["action"] == "platformPlan":
        plan, _ = (ms_plan if req["source"] == "ModelScope" else ollama_plan)(req["id"])
        if req.get("snapshot") and plan["rev"] != req["snapshot"]:
            raise ValueError(message_text('Набор файлов изменился после поиска. Выполните поиск ещё раз.'))
        return plan
    if req["action"] == "inspect":
        return inspect_link(req["url"])
    if req["action"] == "linkTarget":
        return link_target(req["url"])
    disk = Path(req["disk"])
    if not disk.is_absolute() or not disk.is_dir():
        raise ValueError(message_text('Выберите подключённый диск или существующую папку'))
    if req["action"] == "planFavorite":
        model = core["catalog"]()[req["key"]] if "key" in req else register_model(req)
        prepare_favorites(disk, [model])
        return model
    if req["action"] in ("organizationPlan","organize"):
        return core["organize_models"](disk, preview=req["action"] == "organizationPlan")
    if req["action"] in ("destination", "favoriteDestination"):
        catalog = core["catalog"]()
        favorite = req["action"] == "favoriteDestination"
        if favorite and "key" in req:
            return str(core["model_folder"](catalog[req["key"]], disk, reuse_equivalent=False))
        names = sorted(req["files"])
        key = str(max([999] + [int(k) for k in catalog]) + 1)
        model = dict(key=key, name=req["repo"].split("/")[-1], repo=req["repo"], rev=req["revision"],
                     quant=req["variant"], purposes=req["purposes"], size=req["size"], count=len(names), patterns=names,
                     source=req.get("source","Hugging Face"))
        if req.get("recipeKey"):
            registered = catalog[req["recipeKey"]]
            if (registered.get("personal") or registered["repo"] != model["repo"] or registered["rev"] != model["rev"]
                    or registered["quant"] != model["quant"] or registered["size"] != req["size"]):
                raise ValueError(message_text("Вариант недоступен"))
        else:
            registered = matching_model(catalog, model, names, req["size"])
        target = registered or model
        if favorite and registered and registered.get("personal"):
            target = dict(registered, purposes=req["purposes"])
        path = str(core["model_folder"](target, disk, canonical=registered is None, reuse_equivalent=not favorite))
        if favorite:
            return path
        if req.get("includeMatch"):
            state = core["storage_root"](disk) / ".download-queue.json"
            return dict(path=path, key=registered["key"] if registered else None, freeBytes=shutil.disk_usage(disk).free,
                        hasQueue=state.exists() and bool(json.loads(state.read_text())),
                        **preview_budget(req, target, disk, Path(path)))
        return path
    if req["live"]:
        model = register_model(req)
        return dict(model=model, hadQueue=True) if req.get("includeQueueState") else model
    root = core["storage_root"](disk)
    root.mkdir(exist_ok=True)
    with (root / ".queue.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = root / ".download-queue.json"
        pending = json.loads(state.read_text()) if state.exists() else []
        if req["action"] == "editSavedQueue":
            keys = [m["key"] for m in pending]
            wanted = req["keys"]
            if keys != req["previous"] or len(set(wanted)) != len(wanted) or not set(wanted).issubset(keys):
                raise ValueError(message_text('Очередь изменилась. Выберите папку повторно.'))
            by_key = {m["key"]: m for m in pending}
            result = [by_key[key] for key in wanted]
            core["save_json"](state, result)
            return result
        if req["action"] == "enqueue":
            catalog = core["catalog"]()
            chosen = req["keys"] if "keys" in req else [req["key"]]
            models = [catalog[key] for key in dict.fromkeys(chosen)]
            result = models if "keys" in req else models[0]
        else:
            result = register_model(req)
            catalog = core["catalog"]()
            chosen = req.get("selected", []) + [result["key"]]
        had_queue = bool(pending)
        known = {m["key"] for m in pending}
        for key in chosen:
            if key not in known:
                pending.append(catalog[key])
                known.add(key)
        core["save_json"](state, pending)
        return dict(model=result, hadQueue=had_queue) if req.get("includeQueueState") else result


def prepare_favorites(disk, models):
    if not disk.is_absolute() or not disk.is_dir():
        raise ValueError(message_text('Выберите подключённый диск или существующую папку'))
    settings = core["PERSONAL"].with_name("favorite-storage.json")
    settings.parent.mkdir(parents=True, exist_ok=True)
    folders = []
    with settings.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        plans = json.loads(settings.read_text()) if settings.exists() else {}
        for model in models:
            folder = core["model_folder"](model, disk, reuse_equivalent=False)
            existed = folder.is_dir()
            folder.mkdir(parents=True, exist_ok=True)
            plans[model["key"]] = str(disk.resolve())
            folders.append(dict(key=model["key"], folder=str(folder), created=not existed))
        core["save_json"](settings, plans)
    return folders


def scan_error(error):
    if not isinstance(error, FileNotFoundError):
        raise error


def strata_libraries():
    home = Path.home()
    store = Path(os.environ.get("STRATA_HOME") or home/".strata")
    config = Path(os.environ.get("XDG_CONFIG_HOME") or home/".config")
    share = Path(os.environ.get("XDG_DATA_HOME") or home/".local/share")
    components = Path(os.environ.get("STRATA_COMPONENTS_DIR") or share/"strata/components")

    def setting(file, key):
        path = Path(file)
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
            value = data.get(key)
            if isinstance(value,str) and Path(value).expanduser().is_absolute():
                stamp = data.get("data_dir_at") if key == "data_dir" else None
                return (stamp if isinstance(stamp,(int,float)) and stamp > 0 else path.stat().st_mtime,
                        Path(value).expanduser())
        except (OSError, ValueError, AttributeError):
            pass
        return None

    app = setting(os.environ.get("STRATA_SETTINGS_FILE") or components.parent/"app-settings.json", "data_dir")
    if not app:
        app = setting(store/"data/native-host.json", "downloadDirectory")
    terminal = setting(os.environ.get("STRATA_TERMINAL_SETTINGS_FILE") or config/"strata/settings.json", "data_dir")
    native = terminal if terminal and terminal[1].is_dir() and (not app or terminal[0] > app[0]) else app
    saved = setting(store/"data/state.json", "modelsDir")
    documents = Path(os.environ.get("STRATA_DOCUMENTS_DIR") or home/"Documents")
    default = Path(os.environ.get("STRATA_MODELS_DIR") or documents/"Strata/Models")
    roots = [saved[1]] if saved else [default,store/"models"]
    if native:
        roots.insert(0,native[1]/"models")
    unique = {}
    for path in roots:
        if path.is_dir():
            stat = path.stat()
            unique.setdefault((stat.st_dev,stat.st_ino),path.resolve())
    return list(unique.values())


def strata_weights(folder, names):
    weights, vision = [], []
    for name in sorted(names):
        if not name.lower().endswith(".strata"):
            continue
        path = folder/name
        try:
            with path.open("rb") as stream:
                head = stream.read(32)
                size = os.fstat(stream.fileno()).st_size
                if len(head) != 32 or head[:8] != b"STRATA\x00\x01":
                    continue
                offset, length = struct.unpack_from("<QQ",head,16)
                if offset < 4096 or length < 4 or offset + length > size:
                    continue
                stream.seek(offset)
                if stream.read(4) != b"\x28\xb5\x2f\xfd":
                    continue
        except FileNotFoundError:
            continue
        (vision if name.lower().endswith("-vision.strata") else weights).append((path,size))
    for path,size in weights:
        has_vision = len(weights) == 1 and bool(vision)
        yield dict(name=path.stem, detail="Native + Vision" if has_vision else "Native",path=str(path),
                   size=size + (sum(n for _,n in vision) if has_vision else 0))


def installed_models(disk, *, search=False, include_identity=False, scan_lm_volume=False):
    if not disk.is_dir():
        raise FileNotFoundError(disk)
    catalog = {(m["repo"], m["rev"], tuple(m["patterns"])): m for m in core["catalog"]().values()}
    result = []
    roots = {core["storage_root"](disk): ""}
    system_library = disk.resolve() == Path.home().resolve()
    volume_library = system_library or disk.resolve().parent == Path("/Volumes")
    lm_root = core["lm_models_root"]()
    if (volume_library or scan_lm_volume) and lm_root.is_dir() and lm_root.stat().st_dev == disk.stat().st_dev:
        roots = {path: origin for path, origin in roots.items() if path.resolve() != lm_root}
        roots[lm_root] = "LM Studio"
    if not search and volume_library:
        for root in strata_libraries():
            if root.stat().st_dev == disk.stat().st_dev:
                roots[root] = "Strata"
    resolved_roots = {path.resolve() for path in roots}
    for root, origin in roots.items():
        for directory, children, names in os.walk(root, onerror=scan_error):
            folder = Path(directory)
            children[:] = [name for name in children if not name.startswith(".") and
                           (len(roots) == 1 or (folder/name).resolve() not in resolved_roots)]
            if ".download-files.json" in names:
                children.clear()
                try:
                    manifest = json.loads((folder / ".download-files.json").read_text())
                    repo, rev, patterns = manifest["identity"]
                    files = manifest["files"]
                    model = catalog.get((repo, rev, tuple(patterns))) or dict(
                        name=repo, quant="", repo=repo, rev=rev, patterns=patterns,
                        count=len(files), size=sum(f["size"] for f in files))
                    files = core["model_files"](model, folder, cache=False, cached_only=True)
                    expected = {f["rfilename"]: f["size"] for f in files}
                    for base, parts in core["file_groups"](files, model=model).items():
                        expected[base] = sum(expected.pop(f["rfilename"]) for f in parts)
                    if expected and all((folder / n).is_file() and (folder / n).stat().st_size == size
                                        for n, size in expected.items()):
                        row = dict(name=model["name"], detail=model["quant"], path=directory, size=model["size"])
                        if include_identity:
                            row.update(key=model.get("key"), rev=rev)
                        integrity = core["integrity_status"](folder, model, files)
                        if integrity != "size" or search:
                            row["integrity"] = integrity
                        if search:
                            row.update(key=model.get("key"), repo=repo, rev=rev, source=model.get("source","Hugging Face"),
                                       files=[f["rfilename"] for f in files])
                        result.append(row)
                except (FileNotFoundError, ValueError, KeyError, TypeError):
                    continue
            else:
                rows = list(local_weights(folder, names, search=search))
                if origin == "Strata":
                    rows.extend(strata_weights(folder,names))
                for row in rows:
                    if search:
                        parts = folder.relative_to(root).parts
                        if origin != "LM Studio" or len(parts) < 2:
                            continue  # No reliable repository identity for a loose file elsewhere.
                        if row.get("fileSizes") is not None and len(parts) > 2:
                            prefix = "/".join(parts[2:]) + "/"
                            row["fileSizes"] = {prefix + n:v for n,v in row["fileSizes"].items()}
                            row["files"] = list(row["fileSizes"])
                        row.update(repo="/".join(parts[:2]), source="Hugging Face", detail=row["name"])
                    elif origin:
                        row["detail"] = origin + " · " + row["detail"]
                    result.append(row)
    return sorted(result, key=lambda item: (item["name"].casefold(), item["path"]))


def gguf_tensor_count(path):
    """Read the GGUF directory without loading tensor payloads into memory."""
    with path.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        if stream.read(4) != b"GGUF":
            raise ValueError("GGUF magic")
        version = stream.read(4)
        endian = ">" if version == b"\x00\x00\x00\x03" else "<"
        if len(version) != 4 or struct.unpack(endian + "I", version)[0] not in (2, 3):
            raise ValueError("GGUF version")

        def number(fmt):
            return struct.unpack(endian + fmt, stream.read(struct.calcsize(fmt)))[0]

        def skip(length):
            if length > size - stream.tell():
                raise ValueError("Truncated GGUF")
            stream.seek(length, os.SEEK_CUR)

        tensors, metadata = number("Q"), number("Q")
        if tensors * 24 + metadata * 13 > size - stream.tell():
            raise ValueError("Truncated GGUF directory")
        widths = {0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8}
        alignment = 32
        for _ in range(metadata):
            length = number("Q")
            if not 0 < length <= 65535:
                raise ValueError("GGUF metadata key")
            key = stream.read(length)
            kind = number("I")
            if key == b"general.alignment" and kind == 4:
                alignment = number("I")
                if not alignment or alignment % 8:
                    raise ValueError("GGUF alignment")
                continue
            count = 1
            if kind == 9:
                kind, count = number("I"), number("Q")
            if kind == 8:
                if count > (size - stream.tell()) // 8:
                    raise ValueError("Truncated GGUF strings")
                for _ in range(count):
                    skip(number("Q"))
            else:
                skip(widths[kind] * count)

        last_end = 0
        for _ in range(tensors):
            skip(number("Q"))
            dimensions = number("I")
            if not 1 <= dimensions <= 4:
                raise ValueError("GGUF tensor dimensions")
            elements = 1
            for _ in range(dimensions):
                elements *= number("Q")
            kind, offset = number("I"), number("Q")
            if not elements or offset % alignment:
                raise ValueError("GGUF tensor layout")
            # Exact size for scalar types, conservative lower bound for quantized tensors.
            width = {0:4, 1:2, 24:1, 25:2, 26:4, 27:8, 28:8, 30:2}.get(kind)
            last_end = max(last_end, offset + (elements * width if width else (elements + 7) // 8))
        start = (stream.tell() + alignment - 1) // alignment * alignment
        if tensors and start + last_end > size:
            raise ValueError("Missing GGUF tensor data")
        return tensors


def safetensor_names(path):
    """Validate the directory and byte ranges without reading tensor payloads."""
    with path.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        length, = struct.unpack("<Q", stream.read(8))
        if not 2 <= length <= min(size - 8, 100_000_000):
            raise ValueError("Safetensors header size")
        header = stream.read(length)
    if not header.startswith(b"{"):
        raise ValueError("Safetensors header")
    tensors = json.loads(header)
    if not isinstance(tensors, dict):
        raise ValueError("Safetensors directory")
    tensors.pop("__metadata__", None)
    bits = {"BOOL":8, "I8":8, "U8":8, "I16":16, "U16":16, "F16":16, "BF16":16,
            "I32":32, "U32":32, "F32":32, "I64":64, "U64":64, "F64":64,
            "F8_E4M3":8, "F8_E5M2":8, "F8_E8M0":8, "F4":4, "F6_E2M3":6, "F6_E3M2":6,
            "C64":64}
    ranges = []
    for info in tensors.values():
        start, end = info["data_offsets"]
        shape, dtype = info["shape"], info["dtype"]
        if (not isinstance(shape, list) or any(type(n) != int or n < 0 for n in shape)
                or type(start) != int or type(end) != int or end < start
                or not isinstance(dtype, str) or not dtype):
            raise ValueError("Safetensors tensor layout")
        if dtype in bits and (end - start) * 8 != math.prod(shape) * bits[dtype]:
            raise ValueError("Safetensors tensor size")
        ranges.append((start,end))
    offset = 0
    for start, end in sorted(ranges):
        if start != offset:
            raise ValueError("Safetensors discontinuous data")
        offset = end
    if not tensors or offset != size - length - 8:
        raise ValueError("Safetensors incomplete file")
    return tensors.keys()


def local_weights(folder, names, *, search=False):
    groups = collections.defaultdict(list)
    for name in names:
        if not name.lower().endswith(".gguf") or name.lower().startswith(("mmproj", "mtp-")):
            continue
        shard = core["GGUF_SHARD"].fullmatch(name)
        groups[shard[1] if shard else name].append(dict(rfilename=name))
    for group, files in groups.items():
        try:
            core["file_groups"](files)
            paths = sorted(folder / f["rfilename"] for f in files)
            counts = [gguf_tensor_count(path) for path in paths]
            if any(counts):
                row = dict(name=group, detail="GGUF", path=str(paths[0]), size=sum(p.stat().st_size for p in paths))
                if search:
                    row["projectorFiles"] = {n:(folder / n).stat().st_size for n in names if projector_file(n)
                                             and n.lower().endswith(".gguf") and (folder / n).is_file()}
                yield row
        except (FileNotFoundError, ValueError, KeyError, struct.error):
            continue
    if "config.json" in names:
        try:
            index = folder / "model.safetensors.index.json"
            if index.is_file():
                mapping = json.loads(index.read_text())["weight_map"]
                wanted = collections.defaultdict(set)
                for tensor, shard in mapping.items():
                    wanted[shard].add(tensor)
            else:
                wanted = {"model.safetensors":set()}
            valid = {}
            for name, required in wanted.items():
                path = core["contained"](folder, folder / name)
                if path.is_file() and required.issubset(safetensor_names(path)):
                    valid[name] = path.stat().st_size
            complete = bool(valid) and len(valid) == len(wanted)
            if valid and (complete or search):
                sizes = dict(valid)
                for base, dirs, files in os.walk(folder, onerror=scan_error):
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    for n in files:
                        path = Path(base) / n
                        if (n.startswith(".") or n.endswith((".partial",".safetensors",".gguf")) or
                                not payload_file(n) or not path.is_file()):
                            continue
                        sizes[str(path.relative_to(folder))] = path.stat().st_size
                row = dict(name=folder.name, detail="Safetensors", path=str(folder), size=sum(sizes.values()))
                if search:
                    row.update(fileSizes=sizes, files=list(sizes), state="installed" if complete else "partial")
                yield row
        except (FileNotFoundError, ValueError, TypeError, KeyError, AttributeError, struct.error):
            pass


def saved_progress(disk):
    state = core["storage_root"](disk) / ".download-queue.json"
    result = {}
    for m in json.loads(state.read_text()) if state.is_file() else []:
        try:
            folder = core["model_folder"](m, disk, reuse_equivalent=False)
            files = core["model_files"](m, folder, cache=False, cached_only=True)
            if files is not None:
                remaining, _, _ = core["space_for_model"](m, folder, files)
                result[m["key"]] = m["size"] - remaining
        except (OSError, KeyError, TypeError, ValueError):
            # Progress is optional. The normal preflight reports invalid files.
            continue
    return result


def variant_index(paths):
    locations, failed = [], []
    for path in paths:
        disk = Path(path)
        try:
            installed = installed_models(disk, search=True)
            rows = [dict(row, disk=path, state=row.get("state", "installed")) for row in installed]
            installed_keys = {row.get("key") for row in rows if row["state"] == "installed"}
            queue = core["storage_root"](disk) / ".download-queue.json"
            pending = json.loads(queue.read_text()) if queue.is_file() else []
            progress = saved_progress(disk) if any(not m.get("downloadStarted") for m in pending) else {}
            for m in pending:
                if m["key"] in installed_keys:
                    continue
                paused = m.get("downloadStarted") or 0 < progress.get(m["key"], 0) < m["size"]
                rows.append(dict(key=m["key"], name=m["name"], repo=m["repo"], rev=m["rev"], detail=m["quant"],
                                 source=m.get("source","Hugging Face"), size=m["size"], disk=path,
                                 state="paused" if paused else "queued", files=m["patterns"]))
            locations.extend(rows)
        except (OSError, ValueError, KeyError, TypeError):
            failed.append(path)
    return dict(locations=locations, failed=failed)


def variant_locations(paths):
    return variant_index(paths)["locations"]


def drive_library(paths):
    catalog = core["catalog"]()
    settings = core["PERSONAL"].with_name("favorite-storage.json")
    assignments = json.loads(settings.read_text()) if settings.exists() else {}
    installed, planned, failed = {}, {}, []
    for base in dict.fromkeys(Path(p).resolve() for p in paths):
        def plan(m, state):
            record = dict(key=m["key"], rev=m["rev"], name=m["name"], detail=m["quant"],
                          size=m["size"], state=state, disk=str(base))
            planned[(str(base), m["key"], m["rev"])] = record
        for key, destination in assignments.items():
            if key in catalog and Path(destination).resolve() == base:
                plan(catalog[key], "planned")
        try:
            for row in installed_models(base, include_identity=True):
                installed[row["path"]] = row
            queue = core["storage_root"](base) / ".download-queue.json"
            pending = json.loads(queue.read_text()) if queue.is_file() else []
            progress = saved_progress(base) if any(not m.get("downloadStarted") for m in pending) else {}
            for m in pending:
                paused = m.get("downloadStarted") or 0 < progress.get(m["key"], 0) < m["size"]
                plan(m, "paused" if paused else "queued")
        except (OSError, ValueError, KeyError, TypeError) as exc:
            failed.append(str(exc))
    present = {(row.get("key"), row.get("rev")) for row in installed.values()}
    return dict(installed=sorted(installed.values(), key=lambda r: (r["name"].casefold(), r["path"])),
                planned=[r for r in planned.values() if (r["key"], r["rev"]) not in present],
                errors=failed)


def main():
    if sys.argv[1:2] == ["--drive-library"] and len(sys.argv) > 2:
        print(json.dumps(drive_library(sys.argv[2:]), ensure_ascii=False))
        return
    if sys.argv[1:] == ["--search-stream"]:
        os.setpgid(0, 0)
        def publish(page):
            print(json.dumps(page, ensure_ascii=False), flush=True)
        page = search_all_catalogs(json.load(sys.stdin), publish)
        publish(dict(page, final=True))
        return
    if sys.argv[1:2] == ["--variant-index"]:
        print(json.dumps(variant_index(sys.argv[2:]), ensure_ascii=False))
        return
    if sys.argv[1:2] == ["--variant-locations"]:
        print(json.dumps(variant_locations(sys.argv[2:]), ensure_ascii=False))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--prepare-hdd":
        models = [m for m in core["catalog"]().values() if not m.get("personal") and "HDD" in m["roles"]]
        print(json.dumps(prepare_favorites(Path(sys.argv[2]), models), ensure_ascii=False, indent=2))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--inventory":
        print(json.dumps(installed_models(Path(sys.argv[2]), scan_lm_volume=True), ensure_ascii=False))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "--queue-progress":
        print(json.dumps(saved_progress(Path(sys.argv[2]))))
        return
    if sys.argv[1:] == ["--import"]:
        os.setpgid(0, 0)
        print(json.dumps(import_request(), ensure_ascii=False))
        return
    if sys.argv[1:] == ["--catalog"]:
        print(json.dumps(list(core["catalog"]().values()), ensure_ascii=False))
        return
    core["network_wait"].set(lambda label, delay: emit("reconnect", file=label, delay=delay))
    os.setpgid(0, 0)
    req = json.loads(sys.stdin.readline())
    disk = Path(req["disk"])
    if not disk.is_dir():
        raise ValueError(message_text('Папка недоступна'))
    root = core["storage_root"](disk)
    root.mkdir(exist_ok=True)
    state = root / ".download-queue.json"
    with (root / ".queue.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        saved = json.loads(state.read_text()) if state.exists() else []
        if [m["key"] for m in saved] != req["previous"]:
            raise ValueError(message_text('Очередь изменилась. Выберите папку повторно.'))
        catalog = core["catalog"]()
        pending = saved if req["resume"] else [catalog[k] for k in req["ids"]]
        if "resumeFirst" in req:
            key = req["resumeFirst"]
            if not req["resume"] or not any(m["key"] == key for m in pending):
                raise ValueError(message_text('Очередь изменилась. Выберите папку повторно.'))
            pending = sorted(pending, key=lambda m: m["key"] != key)
        if not pending:
            raise ValueError(message_text('Выберите модели'))
        counts = {}
        total = sum(m["size"] for m in pending)
        def row(m, remaining):
            counts[m["key"]] = m["size"] - remaining
        fits = core["preview_queue"](pending, disk, row)
        if not fits:
            raise ValueError(message_text('Недостаточно свободного места'))
        emit("ready", total=total, done=sum(counts.values()))
        start = sys.stdin.readline().strip()
        if start in ("start ru", "start en"):
            os.environ["MODEL_DOWNLOADER_LANGUAGE"] = start.split()[1]
        elif start != "start":
            return
        pending[0] = dict(pending[0], downloadStarted=True)
        core["save_json"](state, pending)
        lock = threading.Condition()
        finished = []
        generation = 0
        appending = False

        def announce(ack=False):
            emit("queue", pending=[m["key"] for m in pending], finished=finished,
                 generation=generation, total=total, done=sum(counts.values()), ack=ack)

        def edit(command):
            nonlocal total, generation
            append = command.get("append")
            available = dict(catalog)
            requested = [append] if isinstance(append, str) else append
            if append is None:
                requested = command["pending"]
            if any(key not in available for key in requested):
                available.update(core["catalog"]())
            while True:
                with lock:
                    old_keys = [m["key"] for m in pending]
                    checked_generation = generation
                    available.update({m["key"]: m for m in pending})
                    if append is not None:
                        known = set(old_keys + finished)
                        additions = [key for key in dict.fromkeys(requested) if key not in known]
                        if not additions:
                            announce(ack=True)
                            return
                        keys = old_keys + additions
                    else:
                        if not pending or command["generation"] != generation:
                            raise ValueError(message_text('Очередь уже перешла к следующей модели. Повторите изменение.'))
                        keys = requested
                        if not keys or keys[0] != old_keys[0] or len(set(keys)) != len(keys):
                            raise ValueError(message_text('Текущая модель закреплена первой в очереди.'))
                        if set(keys).intersection(finished):
                            raise ValueError(message_text('Эта модель уже завершена.'))
                    proposed = [available[key] for key in keys]
                # Removing entries can only reduce disk requirements. Reordering can change the MiMo peak.
                existing_order = [key for key in old_keys if key in keys]
                observed = {}
                fits = keys == existing_order or core["preview_queue"](proposed, disk,
                    lambda m, left: observed.update({m["key"]: m["size"] - left}),
                    output=lambda *args, **kwargs: None)
                with lock:
                    if checked_generation != generation:
                        if append is not None:
                            continue
                        raise ValueError(message_text('Текущая модель завершилась. Повторите изменение.'))
                    if not fits:
                        raise ValueError(message_text('Недостаточно места для изменённой очереди.'))
                    core["save_json"](state, proposed)
                    for key in set(old_keys) - set(keys):
                        counts.pop(key, None)
                    for key in set(keys) - set(old_keys):
                        counts[key] = observed[key]
                    total += sum(m["size"] for m in proposed) - sum(m["size"] for m in pending)
                    pending[:] = proposed
                    generation += 1
                    announce(ack=True)
                    return

        def listen():
            nonlocal appending
            # Use an independent descriptor so interpreter shutdown never waits on stdin's buffer.
            with os.fdopen(os.dup(sys.stdin.fileno()), encoding="utf-8") as commands:
                for line in commands:
                    try:
                        command = json.loads(line)
                        if command.get("language") in ("en", "ru"):
                            os.environ["MODEL_DOWNLOADER_LANGUAGE"] = command["language"]
                            continue
                        with lock:
                            if "pauseModel" in command:
                                if not pending or pending[0]["key"] != command["pauseModel"]:
                                    raise ValueError(message_text('Очередь уже перешла к следующей модели. Повторите изменение.'))
                                emit("pausing")
                                os.killpg(os.getpgrp(), signal.SIGINT)
                                return
                            appending = "append" in command
                        edit(command)
                    except (ValueError, KeyError, OSError, RuntimeError, subprocess.CalledProcessError) as exc:
                        with lock:
                            emit("editError", message=str(exc))
                    finally:
                        with lock:
                            appending = False
                            lock.notify_all()

        announce()
        threading.Thread(target=listen, daemon=True).start()
        samples = collections.deque()
        last_file = None
        def progress(m, done, phase, name):
            nonlocal last_file
            stamp = time.monotonic()
            file_id = (m["key"], name)
            if phase != "network" or last_file != file_id:
                samples.clear()
            last_file = file_id
            speed = 0
            if phase == "network":
                samples.append((stamp, done))
                while len(samples) > 2 and samples[1][0] <= stamp - 6:
                    samples.popleft()
                dt = stamp - samples[0][0]
                if dt >= 0.1:
                    speed = max(0, (done - samples[0][1]) / dt)
            with lock:
                counts[m["key"]] = done
                emit("progress", key=m["key"], model=m["name"], file=name, phase=phase,
                 done=done, total=m["size"], queueDone=sum(counts.values()),
                 queueTotal=total, speed=speed)
        while True:
            with lock:
                lock.wait_for(lambda: pending or not appending)
                if not pending:
                    break
                m = pending[0]
                if not m.get("downloadStarted"):
                    m = pending[0] = dict(m, downloadStarted=True)
                    core["save_json"](state, pending)
            core["download"](m, disk, progress)
            with lock:
                core["save_json"](state, pending[1:])
                pending.pop(0)
                finished.append(m["key"])
                counts[m["key"]] = m["size"]
                generation += 1
                announce()
        emit("complete", total=total)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        emit("paused")
    except Exception as exc:
        if sys.argv[1:] == ["--import"]:
            message = str(exc) or message_text('Вариант недоступен')
            if isinstance(exc, BlockingIOError):
                message = message_text('Очередь этой папки открыта другим загрузчиком.')
            if isinstance(exc, subprocess.CalledProcessError) and exc.returncode == 22:
                message = message_text('Hugging Face не предоставил доступ к репозиторию или ревизии (HTTP ') + (exc.output or b"?").decode() + ")."
            print(json.dumps({"error": message}))
        else:
            emit("error", message=str(exc))
        sys.exit(1)
