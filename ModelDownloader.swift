import SwiftUI
import AppKit
import Combine
import Sparkle

let purposeOptions = ["Текст и диалог", "Код", "Анализ изображений", "Распознавание текста (OCR)", "Эмбеддинги", "Реранжирование", "Генерация изображений", "Редактирование изображений", "Управление генерацией", "Распознавание речи", "Синтез речи", "Генерация видео"]
let providers = ["Все каталоги", "Hugging Face", "ModelScope", "LM Studio", "Ollama Library"]
let rankingNames = ["downloads": "Скачивания", "likes": "Звёзды", "trending": "Тренды"]

struct StorageVolume: Identifiable {
    let root: URL, destination: URL, name: String, internalDisk: Bool, readOnly: Bool
    let free: Int64?
    var id: String { root.path }

    func folders(to url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        let prefix = root.standardizedFileURL.pathComponents
        return Array(components.dropFirst(components.starts(with:prefix) ? prefix.count : 1))
    }
}

enum AppLanguage: String {
    case ru, en
    var locale: Locale { Locale(identifier: rawValue) }

    private static let english = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    func text(_ key: String) -> String {
        guard self == .en else { return key }
        return Self.english?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
    func variantLabel(_ label:String) -> String {
        label.components(separatedBy:" · ").map(text).joined(separator:" · ")
    }
    func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: args)
    }
    func fileSize(_ bytes: Double) -> String {
        guard bytes >= 1 else { return text("0 Б") }
        return Int64(bytes).formatted(.byteCount(style: .decimal).locale(locale))
    }
}

enum AppTheme: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self { case .system: return "Системная"; case .light: return "Светлая"; case .dark: return "Тёмная" }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct Model: Codable, Identifiable {
    let key, name, quant, roles: String
    let source, repo, rev: String?
    let patterns: [String]?
    let purposes: [String]?
    var labels: [String] { (purposes ?? []).isEmpty ? ["Не указано"] : purposes! }
    let personal, downloadStarted: Bool?
    let size: Int64
    var id: String { key }
}
final class FavoriteLocation: ObservableObject, Identifiable {
    let id = UUID()
    let model: Model?
    @Published var selected: String
    @Published var preview: URL?
    @Published var resolvedDrive: URL?
    @Published var error = ""
    @Published var expanded = false

    init(model:Model?, preferredDrive:String?) {
        self.model = model
        self.selected = preferredDrive ?? ""
    }
}

struct InstalledModel: Decodable, Identifiable {
    let name, detail, path: String
    let size: Int64
    var id: String { path }
}
struct DrivePlan: Decodable, Identifiable {
    let key, name, rev, detail, disk, state: String
    let size: Int64
    var id: String { [disk,key,rev].joined(separator:"|") }
}
struct DriveLibrary: Decodable {
    let installed: [InstalledModel]
    let planned: [DrivePlan]
    let errors: [String]
}
enum DownloadGroup: String, CaseIterable {
    case active = "Активные"
    case paused = "На паузе"
    case queued = "В очереди"
}

struct SearchHit: Codable {
    let id: String
    let downloads, likes: Int?
    let trending: Double?
    let kind, source, url, fingerprint, snapshot: String?
    let purposes: [String]?
    var resultKey: String { (source ?? "") + ":" + id.lowercased() }
    var groupKey: String {
        fingerprint.map { "sha256:" + $0 } ?? resultKey
    }
}
struct SearchPage: Decodable {
    let results: [SearchHit]
    let cursor: String?
    let warnings: [String]?
    var final: Bool?
}
struct VariantLocation: Codable, Identifiable {
    var key, repo, rev, source: String?
    var detail: String
    var size: Int64
    var disk, state: String
    var files: [String]?
    var path: String?
    var fileSizes, projectorFiles: [String:Int64]?
    var integrity: String?
    var id: String { [disk,key ?? "",path ?? "",detail,rev ?? ""].joined(separator:"|") }
}
struct ImportOption: Decodable {
    let keys: [String]?
    var fileSizes: [String:Int64]?
    var recipeKey: String?

    let label: String
    let files: [String]
    let size: Int64
}
struct ExtraFile: Decodable {
    let name: String
    let size: Int64
    var files: [String]?
    var members: [String] { files ?? [name] }
}
struct VariantIndex: Decodable { let locations:[VariantLocation]; let failed:[String] }
struct Registration: Decodable { let model:Model; let hadQueue:Bool }
struct VariantDestination: Decodable { let path:String; let key:String?; let freeBytes:Int64?; let hasQueue:Bool?; let remainingBytes,requiredBytes:Int64? }
struct FileIdentity: Decodable {
    let size: Int64
    let digest: String
}
struct ImportPlan: Decodable {
    var payloads: [String:FileIdentity]?
    let repo, rev: String
    let purposes:[String]?
    let preferred:Int
    let options:[ImportOption]
    let extras:[ExtraFile]
}
let python = Bundle.main.resourceURL!.appendingPathComponent("Python/bin/python3")
let worker = Bundle.main.resourceURL!.appendingPathComponent("model_gui_worker.py")
private func decodeImportReply<T:Decodable>(_ process:Process, output:Pipe, input:Pipe, body:Data, as type:T.Type) throws -> T {
    try input.fileHandleForWriting.write(contentsOf: body)
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let reply = try? JSONSerialization.jsonObject(with:data) as? [String:String]
        throw NSError(domain:"Import",code:1,userInfo:[NSLocalizedDescriptionKey:reply?["error"] ?? "Не удалось получить данные каталога"])
    }
    return try JSONDecoder().decode(T.self,from:data)
}

func eta(_ bytes: Double, _ speed: Double, _ language: AppLanguage) -> String {
    guard speed > 0 else { return "—" }
    let seconds = Int(min(1e9, ceil(max(0, bytes) / speed)))
    if seconds >= 3600 { return language.format("%d ч %02d мин",seconds/3600,(seconds/60)%60) }
    return language.format("%d мин %02d с",seconds/60,seconds%60)
}
class Downloads: ObservableObject {
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "") ?? .en {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "interfaceLanguage")
            if stage == "running", let input {
                // The active worker applies the new language to subsequent log entries.
                let command = ["language": language.rawValue]
                if var data = try? JSONSerialization.data(withJSONObject: command) {
                    data.append(10)
                    try? input.write(contentsOf: data)
                }
            }
        }
    }
    @Published var theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "interfaceTheme") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "interfaceTheme") }
    }
    @Published var organizationNotice = ""
    @Published var organizing = false

    @Published var models = [Model]()
    @Published var ids = [String]()
    @Published var saved = [String]()
    private var savedModels = [Model]()
    @Published private(set) var savedBytes = [String:Int64]()
    @Published private(set) var progressKey: String?
    private var progressRequest = UUID()
    private var receivedQueue = false
    var queueKeys: [String] {
        if stage == "complete" { return [] }
        if stage == "running" || stage == "stopping" && receivedQueue {
            return receivedQueue ? liveIDs : ids
        }
        if stage == "ready" || stage == "preview" { return ids }
        return saved
    }
    func queueModel(_ key: String) -> Model? {
        savedModels.first { $0.key == key } ?? models.first { $0.key == key }
    }
    func group(for key: String) -> DownloadGroup {
        if key == queueKeys.first && (stage == "running" || stage == "stopping" && receivedQueue) {
            return .active
        }
        if queueModel(key)?.downloadStarted == true { return .paused }
        let bytes = savedBytes[key] ?? 0
        if bytes > 0 && bytes < (queueModel(key)?.size ?? 0) { return .paused }
        return .queued
    }
    @Published var focusedDownload: String?
    @Published var addingModels = false
    func openDownloads(focusing key: String? = nil) {
        planningFavorite = false
        focusedDownload = key
        addingModels = false
        section = "Загрузки"; importing = false; choosingQueueModels = false
    }

    var selectedSize: Int64 {
        if ids == saved { return savedModels.reduce(0) { $0 + $1.size } }
        let selected = Set(ids)
        return models.reduce(0) { $0 + (selected.contains($1.key) ? $1.size : 0) }
    }
    @Published var disk = FileManager.default.homeDirectoryForCurrentUser {
        didSet { rememberLibrary(disk) }
    }
    @Published var volumes = [StorageVolume]()
    @Published var storageNotice = ""
    private var observers = [NSObjectProtocol]()
    private var volumeFolders = UserDefaults.standard.dictionary(forKey: "volumeFolders") as? [String:String] ?? [:]
    private var folderKey: String { disk.resolvingSymlinksInPath().standardizedFileURL.path }
    @Published var stage = "idle"
    @Published var status = ""
    @Published var log = ""
    @Published var current = "Текущая модель"
    @Published var file = ""
    @Published var done = 0.0
    @Published var total = 0.0
    @Published var queueDone = 0.0
    @Published var queueTotal = 0.0
    @Published var speed = 0.0
    @Published var showLog = false
    @Published var liveIDs = [String]()
    @Published var editBusy = false
    @Published var editNotice = ""
    @Published var choosingQueueModels = false
    @Published var queueSelection = [String]()
    @Published var section = "Избранное"
    @Published var installed = [InstalledModel]()
    @Published private(set) var drivePlans = [DrivePlan]()
    @Published private(set) var inventoryFolder: URL?
    var viewedLibrary: URL { inventoryFolder ?? disk }
    var viewingDrive: Bool { !importing && section == "Модели на диске" }
    var viewingLibrary: Bool { viewingDrive || !importing && section == "Скачанные модели" }
    func viewLibrary(on drive:StorageVolume) {
        let destination = libraryDestination(for:drive)
        if canEdit && !writing && !drive.readOnly && !sameBase(destination.path,disk) {
            changeFolder(destination)
        }
        addingModels = false; importing = false; choosingQueueModels = false; planningFavorite = false
        section = "Модели на диске"
        inventoryFolder = destination
        refreshInventory()
    }
    func planStatus(_ plan:DrivePlan) -> String {
        if sameBase(plan.disk,disk), queueKeys.contains(plan.key) {
            switch group(for:plan.key) {
            case .active: return "Скачивание"
            case .paused: return "На паузе"
            case .queued: return "В очереди"
            }
        }
        return ["paused":"На паузе","queued":"В очереди"][plan.state] ?? "Запланировано"
    }
    @Published var scanning = false
    @Published var scanError = ""
    private var inventoryRequest = UUID()
    @Published var planningFavorite = false
    @Published var favoriteStorage: [String:String] = {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ModelDownloader/favorite-storage.json")
        guard let data = try? Data(contentsOf:path) else { return [:] }
        return (try? JSONDecoder().decode([String:String].self, from:data)) ?? [:]
    }()
    @Published var purposeFilter = "Все назначения"
    @Published var importPurposes = [String]()
    @Published private var starOverrides = UserDefaults.standard.dictionary(forKey: "modelStars") as? [String:Bool] ?? [:]
    @Published var bookmarks = (UserDefaults.standard.data(forKey: "catalogBookmarks").flatMap {
        try? JSONDecoder().decode([SearchHit].self, from: $0)
    }) ?? []
    func starred(_ model: Model) -> Bool { starOverrides[model.key] ?? (model.personal != true) }
    func toggleStar(_ model: Model) {
        if !starred(model) { chooseFavoriteDrive(model); return }
        starOverrides[model.key] = false
        UserDefaults.standard.set(starOverrides, forKey: "modelStars")
    }
    @Published var favoriteLocation: FavoriteLocation?
    func chooseFavoriteDrive(_ model: Model? = nil) {
        guard !writing, model != nil || plan != nil else { return }
        refreshVolumes()
        let preferred = model.flatMap { favoriteStorage[$0.key] } ?? (model == nil ? importFolder.path : disk.path)
        let drives = volumes.filter { !$0.readOnly }
        let selected = drives.first { $0.destination.standardizedFileURL.path == preferred }
            ?? volume(containing:URL(fileURLWithPath:preferred)).flatMap { $0.readOnly ? nil : $0 }
            ?? drives.first
        favoriteLocation = FavoriteLocation(model:model, preferredDrive:selected?.id)
    }
    func saveFavorite(_ model: Model?, at dest: URL) {
        let request: [String:Any]
        if let model { request = ["action":"planFavorite","key":model.key,"disk":dest.path] }
        else if let plan { request = variantRequest(plan, action:"planFavorite", destination:dest) }
        else { return }
        let hit = model == nil ? currentHit : nil
        importCall(request, as:Model.self) { saved in
            if !self.models.contains(where:{ $0.key == saved.key }) { self.models.append(saved) }
            self.favoriteStorage[saved.key] = dest.resolvingSymlinksInPath().standardizedFileURL.path
            if !self.onSelectedDrive(saved.key) {
                self.queueSelection.removeAll { $0 == saved.key }
                if self.canEdit && !self.saved.contains(saved.key) { self.ids.removeAll { $0 == saved.key } }
            }
            self.starOverrides[saved.key] = true
            UserDefaults.standard.set(self.starOverrides, forKey:"modelStars")
            if let hit {
                self.bookmarks.removeAll { $0.resultKey == hit.resultKey }
                UserDefaults.standard.set(try? JSONEncoder().encode(self.bookmarks), forKey:"catalogBookmarks")
                if self.currentHit?.resultKey == hit.resultKey { self.importFolder = dest; self.importVariantKey = saved.key }
            }
            self.planningFavorite = false
            self.status = self.language.format("Сохранено в избранном · %@",dest.lastPathComponent)
        }
    }
    private func localMatches(_ hit: SearchHit) -> [Model] {
        let id = hit.id.lowercased()
        return models.filter { model in
            let repo = model.repo?.lowercased()
            if hit.kind == "ms" { return model.source == "ModelScope" && repo == id.components(separatedBy:"@")[0] }
            if hit.kind == "tag" { return model.source == "Ollama Library" && id == (repo ?? "") + ":" + model.quant.components(separatedBy:" · ")[0].lowercased() }
            return (hit.source == "Hugging Face" || hit.source == "LM Studio" && hit.kind == "hf")
                && !["Ollama Library","ModelScope"].contains(model.source ?? "") && repo == id
        }
    }
    func bookmarked(_ hit: SearchHit) -> Bool {
        bookmarks.contains { $0.resultKey == hit.resultKey } || localMatches(hit).contains(where: starred)
    }
    func toggleBookmark(_ hit: SearchHit) {
        guard !writing else { return }
        let local = localMatches(hit)
        if !bookmarked(hit) {
            if local.count == 1 { chooseFavoriteDrive(local[0]); return }
            planningFavorite = true; importing = true; importFolder = disk
            selectHit(hit)
            return
        }
        bookmarks.removeAll { $0.resultKey == hit.resultKey }
        for model in local { starOverrides[model.key] = false }
        UserDefaults.standard.set(starOverrides, forKey: "modelStars")
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: "catalogBookmarks")
    }
    func visibleModels(addingToQueue: Bool = false) -> [Model] {
        let queued = addingToQueue ? Set(queueKeys) : []
        return models.filter { !queued.contains($0.key) && starred($0) &&
            (!addingToQueue || onSelectedDrive($0.key)) &&
            (purposeFilter == "Все назначения" || $0.labels.contains(purposeFilter)) }
    }
    func onSelectedDrive(_ key:String) -> Bool {
        favoriteStorage[key] == nil || favoriteStorage[key] == folderKey
    }
    private var explicitImportFolder = false
    private var explicitProjector = false
    func showPlan(_ result: ImportPlan, choosing index:Int? = nil) {
        explicitImportFolder = false; explicitProjector = false
        variant = index ?? result.preferred
        importPurposes = result.purposes ?? []
        plan = result
        configureVariant(result, for:variant)
    }
    func chooseImportDestination(_ folder:URL) {
        explicitImportFolder = true
        importFolder = folder
        if !lastScannedBases.contains(folder.resolvingSymlinksInPath().path) { refreshSearchLocations() }
        if !explicitProjector, let plan { selectDefaultProjector(plan, for:variant) }
    }
    func selectProjector(_ name:String) {
        explicitProjector = true
        extra = name
    }
    private func knownLocations(_ plan:ImportPlan, for index:Int) -> [VariantLocation] {
        guard let hit = currentHit else { return [] }
        return classifiedLocations(for:hit,plan:plan).filter { locationMatches($0,option:plan.options[index],plan:plan) }
    }
    private func sameBase(_ path:String, _ base:URL) -> Bool {
        URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL.path == base.resolvingSymlinksInPath().standardizedFileURL.path
    }
    private func selectDefaultProjector(_ plan:ImportPlan, for index:Int) {
        let choices = projectorChoices(plan, for:index)
        let installed = knownLocations(plan,for:index).filter { $0.state == "installed" && sameBase($0.disk,importFolder) }
        if !installed.isEmpty {
            extra = choices.first { projector in installed.contains { containsProjector(projector,in:$0) } }?.name ?? ""
        } else {
            extra = choices.count == 1 ? choices[0].name : ""
        }
    }
    private func containsProjector(_ projector:ExtraFile,in row:VariantLocation) -> Bool {
        let members = Set(projector.members)
        if let files = row.files, members.isSubset(of:Set(files)) { return true }
        guard let neighbors = row.projectorFiles else { return false }
        let sizes = projector.members.compactMap { name in neighbors[name] ?? neighbors[(name as NSString).lastPathComponent] }
        return sizes.count == members.count && sizes.reduce(0,+) == projector.size
    }
    func configureVariant(_ plan:ImportPlan, for index:Int, resetProjector:Bool = true) {
        guard plan.options.indices.contains(index) else { return }
        if !explicitImportFolder {
            let rows = knownLocations(plan,for:index)
            for state in ["installed","active","paused","queued","planned","partial"] {
                let candidates = rows.filter { $0.state == state && $0.integrity != "changed" }
                let preferred = candidates.first { sameBase($0.disk,disk) } ??
                    candidates.first { volume(containing:URL(fileURLWithPath:$0.disk)) != nil } ?? candidates.first
                if let preferred { importFolder = URL(fileURLWithPath:preferred.disk,isDirectory:true); break }
            }
        }
        if resetProjector { explicitProjector = false }
        if !explicitProjector { selectDefaultProjector(plan, for:index) }
    }
    func installedSelection(_ plan:ImportPlan) -> VariantLocation? {
        knownLocations(plan,for:variant).first { row in
            guard row.state == "installed", row.integrity != "changed", row.path != nil, sameBase(row.disk,importFolder) else { return false }
            return extra.isEmpty || plan.extras.contains { $0.name == extra && containsProjector($0,in:row) }
        }
    }
    func projectorChoices(_ plan:ImportPlan, for index:Int) -> [ExtraFile] {
        guard plan.options[index].label.lowercased().hasSuffix(".gguf") else { return [] }
        let dir = (plan.options[index].files.first as NSString?)?.deletingLastPathComponent ?? ""
        let same = plan.extras.filter { ($0.name as NSString).deletingLastPathComponent == dir }
        return same.isEmpty ? plan.extras.filter {
            let parent = ($0.name as NSString).deletingLastPathComponent.lowercased()
            return parent.isEmpty || ["mmproj","projector","projectors"].contains(parent)
        } : same
    }
    @Published var searchLocations = UserDefaults.standard.data(forKey:"lastVariantLocations").flatMap {
        try? JSONDecoder().decode([VariantLocation].self,from:$0)
    } ?? []
    @Published var indexingLocations = false
    @Published var failedLocationBases = Set<String>()
    private var locationScan = UUID()
    private var lastScannedBases = Set<String>()
    private var knownLibraryBases = Set(UserDefaults.standard.stringArray(forKey:"downloadLibraryBases") ?? [])
    private func rememberLibrary(_ folder:URL) {
        if knownLibraryBases.insert(folder.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
            UserDefaults.standard.set(knownLibraryBases.sorted(),forKey:"downloadLibraryBases")
        }
    }
    func refreshSearchLocations() {
        let registered = knownLibraryBases.union(favoriteStorage.values)
        var bases = Set(volumes.map { libraryDestination(for:$0).resolvingSymlinksInPath().path })
        for drive in volumes {
            let anchor = drive.internalDisk ? FileManager.default.homeDirectoryForCurrentUser : drive.root
            bases.insert(anchor.resolvingSymlinksInPath().path)
        }
        for path in registered where volume(containing:URL(fileURLWithPath:path)) != nil && FileManager.default.fileExists(atPath:path) {
            bases.insert(path)
        }
        if explicitImportFolder, volume(containing:importFolder) != nil {
            bases.insert(importFolder.resolvingSymlinksInPath().path)
        }
        let requested = bases
        lastScannedBases = requested
        let ticket = UUID()
        locationScan = ticket; indexingLocations = true
        DispatchQueue.global(qos:.utility).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = python
            process.arguments = ["-IB", worker.path,"--variant-index"] + requested.sorted()
            process.standardOutput = pipe
            var index: VariantIndex?
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { index = try? JSONDecoder().decode(VariantIndex.self,from:data) }
            }
            let scanned = index
            DispatchQueue.main.async {
                guard self.locationScan == ticket else { return }
                self.indexingLocations = false
                self.failedLocationBases = scanned.map { Set($0.failed) } ?? requested
                if let scanned {
                    let retained = self.searchLocations.filter {
                        self.failedLocationBases.contains($0.disk) || self.volume(containing:URL(fileURLWithPath:$0.disk)) == nil
                    }
                    self.searchLocations = retained + scanned.locations.filter { !self.failedLocationBases.contains($0.disk) }
                    if let data = try? JSONEncoder().encode(self.searchLocations) {
                        UserDefaults.standard.set(data,forKey:"lastVariantLocations")
                    }
                    if let plan = self.plan { self.configureVariant(plan,for:self.variant,resetProjector:false) }
                }
            }
        }
    }
    func diskName(_ base:String) -> String {
        let url = URL(fileURLWithPath:base)
        return volume(containing:url)?.name ?? (url.pathComponents.starts(with:["/","Volumes"]) && url.pathComponents.count > 2 ? url.pathComponents[2] : url.lastPathComponent)
    }
    func locations(for hit:SearchHit) -> [VariantLocation] {
        let id = hit.id.lowercased()
        let repo = id.components(separatedBy:hit.kind == "tag" ? ":" : "@")[0]
        let source = hit.source ?? provider
        func matches(_ origin:String?, _ name:String?, _ quant:String) -> Bool {
            guard name?.lowercased() == repo else { return false }
            if source == "ModelScope" { return origin == source }
            if source == "Ollama Library" {
                return origin == source && (hit.kind != "tag" || id == repo + ":" + quant.components(separatedBy:" · ")[0].lowercased())
            }
            return (source == "Hugging Face" || hit.kind == "hf") && !["Ollama Library","ModelScope"].contains(origin ?? "")
        }
        var rows = searchLocations.filter { matches($0.source,$0.repo,$0.detail) }
        for model in models where matches(model.source,model.repo,model.quant) {
            func record(_ disk:String,_ state:String) -> VariantLocation {
                VariantLocation(key:model.key,repo:model.repo,rev:model.rev,source:model.source,detail:model.quant,
                                size:model.size,disk:disk,state:state,files:model.patterns)
            }
            let activeBase = folderKey
            rows.removeAll { $0.disk == activeBase && $0.key == model.key && ["queued","paused"].contains($0.state) }
            if queueKeys.contains(model.key) && !rows.contains(where:{ $0.key == model.key && $0.disk == activeBase && $0.state == "installed" }) {
                let group = group(for:model.key)
                rows.append(record(activeBase,group == .active ? "active" : group == .paused ? "paused" : "queued"))
            }
            if starred(model), let target = favoriteStorage[model.key], !rows.contains(where:{ $0.key == model.key && $0.disk == target }) {
                rows.append(record(target,"planned"))
            }
        }
        return rows.sorted { ($0.detail,$0.disk) < ($1.detail,$1.disk) }
    }
    func locationText(_ row:VariantLocation) -> String {
        let state = ["active":"Скачивание","queued":"В очереди","paused":"На паузе","installed":"Скачано","planned":"Запланировано","partial":"Неполный комплект"][row.state] ?? row.state
        var text = language.text(state)
        if row.state == "active", progressKey == row.key && total > 0 {
            text += " " + (done / total).formatted(.percent.precision(.fractionLength(0)).locale(language.locale))
        }
        text += " · " + diskName(row.disk)
        if row.state == "installed" || row.state == "partial" {
            text += " · " + language.format("На диске %@",language.fileSize(Double(row.size)))
        }
        if let companions = row.projectorFiles, !companions.isEmpty {
            let summary = companions.keys.sorted().map { name in
                name + " (" + language.fileSize(Double(companions[name] ?? 0)) + ")"
            }.joined(separator:", ")
            text += " · " + language.format("Проекторы рядом: %@",summary)
        }
        if let integrity = row.integrity, let label = ["verified":"Хеш проверен","size":"Размер сверён","changed":"Файлы изменились"][integrity] {
            text += " · " + language.text(label)
        }
        if failedLocationBases.contains(row.disk) { text += " · " + language.text("Не удалось проверить диск") }
        if volume(containing:URL(fileURLWithPath:row.disk)) == nil { text += " · " + language.text("Диск отключён") }
        return text
    }
    func openLocation(_ row:VariantLocation) {
        if ["installed","partial"].contains(row.state), let path=row.path {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])
        } else if let key=row.key {
            if row.disk != folderKey { changeFolder(URL(fileURLWithPath:row.disk,isDirectory:true)) }
            if row.disk == folderKey { openDownloads(focusing:key) }
        }
    }
    private func packageMatches(_ sizes:[String:Int64], option:ImportOption, complete:Bool) -> Bool {
        guard let required = option.fileSizes, !required.isEmpty else { return false }
        let weights = sizes.filter { $0.key.lowercased().hasSuffix(".safetensors") }
        guard !weights.isEmpty, weights.allSatisfy({ required[$0.key] == $0.value }) else { return false }
        if complete { return required.allSatisfy { sizes[$0.key] == $0.value } }
        return sizes.allSatisfy { required[$0.key] == nil || required[$0.key] == $0.value }
    }
    func classifiedLocations(for hit:SearchHit,plan:ImportPlan) -> [VariantLocation] {
        locations(for:hit).map { item in
            guard item.rev == nil, item.state == "installed", let local = item.fileSizes,
                  !plan.options.contains(where:{packageMatches(local,option:$0,complete:true)}) else { return item }
            var row = item
            row.state = "partial"
            return row
        }
    }
    func locationMatches(_ row:VariantLocation, option:ImportOption, plan:ImportPlan) -> Bool {
        if let rev=row.rev, rev != plan.rev { return false }
        if let key=row.key, option.keys?.contains(key) == true { return true }
        if row.rev == nil, let sizes = row.fileSizes {
            let complete = row.state != "partial"
            guard packageMatches(sizes,option:option,complete:complete) else { return false }
            return complete || plan.options.filter { packageMatches(sizes,option:$0,complete:false) }.count == 1
        }
        if let files=row.files, row.rev != nil {
            let projectors = Set(plan.extras.flatMap(\.members))
            return Set(files).subtracting(projectors) == Set(option.files)
        }
        guard row.rev == nil, row.state == "installed", option.size == row.size, let path=row.path else { return false }
        return URL(fileURLWithPath:path).lastPathComponent == (option.files.first as NSString?)?.lastPathComponent
    }
    @Published var importing = false
    @Published var provider = "Все каталоги"
    @Published var ranking = "downloads"
    @Published var currentHit: SearchHit?
    @Published var importPath = ""
    @Published var importFreeBytes: Int64?
    @Published private(set) var importRemainingBytes: Int64?
    @Published private(set) var importRequiredBytes: Int64?
    @Published private(set) var destinationHasQueue = false
    @Published var importVariantKey: String?
    var rankings: [String] {
        if provider == "Ollama Library" { return ["downloads"] }
        return ["Все каталоги","Hugging Face"].contains(provider) ? ["downloads","likes","trending"] : ["downloads","likes"]
    }
    @Published var searchWarnings = [String]()
    @Published var selectedProvider = "Hugging Face"
    @Published var reference = ""
    @Published var browseTitle = ""
    struct SearchLevel { let hits:[SearchHit]; let title:String; let cursor:String? }
    var levels = [SearchLevel]()
    private var searchSnapshot = [String:String]()
    @Published var searchFocusRequest = 0
    private var browsedPurposes = [String]()
    func backLevel() {
        plan = nil; importMessage = ""
        if let old = levels.popLast() { hits = old.hits; browseTitle = old.title; nextCursor = old.cursor }
    }
    @Published private(set) var appliedAuthor = ""
    @Published var author = ""
    @Published var searchPurpose = ""
    @Published var showFilters = false
    @Published var searchText = ""
    @Published var searchFormat = ""
    @Published var hits = [SearchHit]()
    var resultGroups: [[SearchHit]] {
        let byRepository = Dictionary(grouping:hits, by:\.groupKey)
        var seen = Set<String>()
        return hits.compactMap { hit in
            seen.insert(hit.groupKey).inserted ? byRepository[hit.groupKey] : nil
        }
    }
    @Published var nextCursor: String?
    @Published var didSearch = false
    func resetSearch() {
        planningFavorite = false
        cancelLookup(); currentHit = nil; importPath = ""; levels = []; browsedPurposes = []; browseTitle = ""; reference = ""; hits = []; searchWarnings = []; nextCursor = nil; didSearch = false; plan = nil; importMessage = ""
    }
    func search(more: Bool = false) {
        guard !writing else { return }
        if !more {
            resetSearch()
            appliedAuthor = author.trimmingCharacters(in:.whitespacesAndNewlines)
            searchSnapshot = ["action":"search","sort":ranking,"source":provider,
                              "query":searchText.trimmingCharacters(in:.whitespacesAndNewlines),"author":appliedAuthor,
                              "format":provider == "Hugging Face" ? searchFormat : "","purpose":searchPurpose]
        }
        var request = searchSnapshot
        if more && nextCursor == nil { return }
        request["cursor"] = more ? nextCursor : ""
        let previous = more ? hits : []
        let previousWarnings = more ? searchWarnings : []
        let sort = request["sort"] ?? "downloads"
        func show(_ page:SearchPage) {
            var byKey = Dictionary(uniqueKeysWithValues:previous.map { ($0.resultKey,$0) })
            var keys = previous.map(\.resultKey)
            for hit in page.results {
                if byKey.updateValue(hit,forKey:hit.resultKey) == nil { keys.append(hit.resultKey) }
            }
            func metric(_ hit:SearchHit) -> Double {
                switch sort {
                case "likes": return Double(hit.likes ?? -1)
                case "trending": return hit.trending ?? -1
                default: return Double(hit.downloads ?? -1)
                }
            }
            let merged = keys.compactMap { byKey[$0] }
            self.hits = more || request["source"] == "Все каталоги" ? merged.sorted { metric($0) > metric($1) } : merged
            self.searchWarnings = previousWarnings + (page.warnings ?? [])
            self.nextCursor = page.cursor
            self.didSearch = true
        }
        if request["source"] == "Все каталоги" { streamCatalogSearch(request,update:show) }
        else { importCall(request,as:SearchPage.self,success:show) }
    }
    private func streamCatalogSearch(_ request:[String:String],update:@escaping (SearchPage)->Void) {
        cancelLookup()
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = python
        process.arguments = ["-IB", worker.path,"--search-stream"]
        process.environment = ProcessInfo.processInfo.environment.merging(["MODEL_DOWNLOADER_LANGUAGE":language.rawValue]) { _,new in new }
        process.standardInput = input; process.standardOutput = output
        do {
            let body = try JSONEncoder().encode(request)
            try process.run()
            lookup = process
            DispatchQueue.global(qos:.userInitiated).async {
                do {
                    try input.fileHandleForWriting.write(contentsOf:body)
                    try input.fileHandleForWriting.close()
                    let decoder = JSONDecoder()
                    var buffer = Data(), finished = false
                    while true {
                        let chunk = output.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        while let end = buffer.firstIndex(of:10) {
                            let line = buffer[..<end]
                            let page = try decoder.decode(SearchPage.self,from:line)
                            buffer.removeSubrange(...end)
                            finished = page.final == true
                            DispatchQueue.main.async {
                                if self.lookup === process { update(page) }
                            }
                        }
                    }
                    process.waitUntilExit()
                    guard finished && process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                    DispatchQueue.main.async { if self.lookup === process { self.lookup = nil } }
                } catch {
                    DispatchQueue.main.async {
                        guard self.lookup === process else { return }
                        self.cancelLookup(); self.importMessage = error.localizedDescription
                    }
                }
            }
        } catch { importMessage = error.localizedDescription }
    }
    func selectHit(_ hit:SearchHit) {
        cancelLookup(); currentHit = hit; importMessage = ""; plan = nil; extra = ""
        let destinations = Set(localMatches(hit).filter(starred).compactMap { favoriteStorage[$0.key] })
        if destinations.count == 1, let path = destinations.first { importFolder = URL(fileURLWithPath:path,isDirectory:true) }
        else { importFolder = disk }
        let source = hit.source ?? provider
        selectedProvider = source
        switch hit.kind {
        case "lm","lm-page","ollama":
            importCall(["action":"browse","kind":hit.kind!,"id":hit.id,"source":source],as:SearchPage.self) { page in
                if !self.hits.isEmpty {
                    self.levels.append(SearchLevel(hits:self.hits,title:self.browseTitle,cursor:self.nextCursor))
                }
                self.browsedPurposes = hit.purposes ?? []; self.hits=page.results; self.browseTitle=hit.id; self.nextCursor=nil
            }
        case "ms","tag":
            reference=hit.id
            importCall(["action":"platformPlan","source":source,"id":hit.id,"snapshot":hit.snapshot ?? ""],as:ImportPlan.self) { result in
                self.showPlan(result)
                if self.importPurposes.isEmpty {
                    self.importPurposes = hit.purposes ?? (hit.kind == "tag" ? self.browsedPurposes : [])
                }
            }
        default:
            inspectHuggingFace(hit.url ?? "https://huggingface.co/" + hit.id)
        }
    }
    @Published var link = ""
    @Published var importFolder = FileManager.default.homeDirectoryForCurrentUser
    @Published var plan: ImportPlan?
    @Published var variant = 0
    @Published var extra = ""
    @Published var lookup: Process?
    @Published var writing = false
    var busy: Bool { lookup != nil || writing }
    func cancelLookup() {
        if let p = lookup, p.isRunning {
            if kill(-p.processIdentifier, SIGTERM) != 0 { p.terminate() }
        }
        lookup = nil
    }
    @Published var importMessage = ""
    var isLiveDestination: Bool { stage == "running" && importFolder.resolvingSymlinksInPath().standardizedFileURL.path == folderKey }
    var selectedProjectorFiles: [String] { plan?.extras.first { $0.name == extra }?.members ?? [] }
    var importSize: Int64 {
        guard let plan else { return 0 }
        return plan.options[variant].size + (plan.extras.first { $0.name == extra }?.size ?? 0)
    }
    func openImport(fromPicker: Bool = false) {
        planningFavorite = false
        if !fromPicker { addingModels = false; choosingQueueModels = false }
        if !importing && plan == nil { importFolder = disk }
        importing = true
        if hits.isEmpty && !didSearch && !busy && plan == nil { search() }
    }
    func focusSearch() {
        guard !writing else { return }
        if plan != nil || currentHit != nil {
            cancelLookup()
            plan = nil; currentHit = nil; importPath = ""; importMessage = ""
        }
        openImport()
        // Let the search field enter the key window before requesting first responder.
        DispatchQueue.main.async { self.searchFocusRequest += 1 }
    }
    func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath:"/Volumes")
        if panel.runModal() == .OK, let folder = panel.url { chooseImportDestination(libraryBase(for:folder)) }
    }
    private func libraryBase(for selection:URL) -> URL {
        let parent = selection.deletingLastPathComponent()
        if ["Models","Модели"].contains(selection.lastPathComponent),
           let volume = volume(containing:selection), volume.id == self.volume(containing:parent)?.id {
            return parent
        }
        return selection
    }
    func importCall<T:Decodable>(_ request:[String:Any], as type:T.Type, success:@escaping(T)->Void) {
        let changing = ["enqueue","register","planFavorite","organize","organizationPlan","editSavedQueue"].contains(request["action"] as? String ?? "")
        if changing && writing { return }
        if !changing { cancelLookup() }
        let p = Process(), output = Pipe(), input = Pipe()
        p.executableURL = python
        p.environment = ProcessInfo.processInfo.environment.merging(["MODEL_DOWNLOADER_LANGUAGE":language.rawValue]) { _, new in new }
        p.arguments = ["-IB", worker.path,"--import"]
        p.standardInput = input; p.standardOutput = output
        importMessage = ""
        do {
            let body = try JSONSerialization.data(withJSONObject: request)
            try p.run()
            if changing { writing = true } else { lookup = p }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result<T,Error> {
                    try decodeImportReply(p, output:output, input:input, body:body, as:T.self)
                }
                DispatchQueue.main.async {
                    if changing { self.writing = false }
                    else if self.lookup === p { self.lookup = nil } else { return }
                    switch result {
                    case .success(let value): success(value)
                    case .failure(let error):
                        self.importMessage = error.localizedDescription
                        if changing { self.status = error.localizedDescription }
                        if self.organizing && ["organize","organizationPlan"].contains(request["action"] as? String ?? "") {
                            self.organizing = false
                            self.organizationNotice = error.localizedDescription
                        }
                    }
                    if !self.writing, !self.deferredWrites.isEmpty {
                        let pending = self.deferredWrites.removeFirst()
                        self.saveQueuedModels(pending.keys, at:pending.destination)
                    }
                }
            }
        } catch {
            importMessage = error.localizedDescription; status = importMessage
            if ["organize","organizationPlan"].contains(request["action"] as? String ?? "") {
                organizing = false; organizationNotice = importMessage
            }
        }
    }
    private func destinationRequest(_ plan:ImportPlan, at folder:URL) -> [String:Any] {
        let option = plan.options[variant]
        var request: [String:Any] = ["action":"destination","source":selectedProvider,"disk":folder.path,"repo":plan.repo,"revision":plan.rev,
                "files":option.files + selectedProjectorFiles,"size":importSize,
                "purposes":importPurposes,"variant":option.label,"includeMatch":true]
        if option.recipeKey == nil, let identities = plan.payloads {
            var payloads = [String:[String:Any]]()
            for name in option.files + selectedProjectorFiles {
                if let identity = identities[name] {
                    payloads[name] = ["size":identity.size,"digest":identity.digest]
                }
            }
            if !payloads.isEmpty { request["payloads"] = payloads }
        }
        request["recipeKey"] = option.recipeKey
        return request
    }

    func favoriteFolder(_ model:Model?, at destination:URL) async throws -> URL {
        var request: [String:Any]
        if let model { request = ["key":model.key,"disk":destination.path] }
        else if let plan { request = destinationRequest(plan, at:destination) }
        else { throw CocoaError(.fileNoSuchFile) }
        request["action"] = "favoriteDestination"
        let path:String = try await readPreview(request, as:String.self)
        return URL(fileURLWithPath:path,isDirectory:true)
    }
    func readPreview<T:Decodable>(_ request:[String:Any], as type:T.Type) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject:request)
        let lang = language.rawValue
        return try await Task.detached {
            let process = Process(), output = Pipe(), input = Pipe()
            process.executableURL = python
            process.arguments = ["-IB", worker.path,"--import"]
            process.environment = ProcessInfo.processInfo.environment.merging(["MODEL_DOWNLOADER_LANGUAGE":lang]) { _,new in new }
            process.standardOutput = output; process.standardInput = input
            try process.run()
            return try decodeImportReply(process,output:output,input:input,body:body,as:T.self)
        }.value
    }

    func updateImportPath() {
        importPath = ""; importVariantKey = nil; importFreeBytes = nil; destinationHasQueue = false
        importRemainingBytes = nil; importRequiredBytes = nil
        guard let plan, !writing else { return }
        importCall(destinationRequest(plan, at:importFolder), as:VariantDestination.self) {
            self.importPath = $0.path; self.importVariantKey = $0.key; self.importFreeBytes = $0.freeBytes
            self.destinationHasQueue = $0.hasQueue == true
            self.importRemainingBytes = $0.remainingBytes; self.importRequiredBytes = $0.requiredBytes
        }
    }
    func inspectLink() {
        resetSearch()
        importCall(["action":"linkTarget","url":link],as:SearchHit.self) { target in
            self.selectHit(target)
        }
    }
    private func inspectHuggingFace(_ url:String) {
        importCall(["action":"inspect","url":url],as:ImportPlan.self) { result in
            self.showPlan(result)
        }
    }
    var importAddsToQueue: Bool {
        addingModels || !canEdit || destinationHasQueue || (isCurrentImportFolder && !saved.isEmpty)
    }
    private var isCurrentImportFolder: Bool {
        importFolder.resolvingSymlinksInPath().standardizedFileURL.path == folderKey
    }
    private func variantRequest(_ plan:ImportPlan, action:String, destination:URL) -> [String:Any] {
        var request: [String:Any] = ["action":action,"pinned":"https://huggingface.co/\(plan.repo)/tree/\(plan.rev)",
            "variant":plan.options[variant].label,"extras":extra.isEmpty ? [] : [extra],"size":importSize,
            "disk":destination.path,"live":isLiveDestination,"source":selectedProvider,
            "reference":reference,"revision":plan.rev,"purposes":importPurposes,
            "selected":[String]()]
        request["recipeKey"] = plan.options[variant].recipeKey
        return request
    }
    func enqueueImport() {
        guard let plan else { return }
        let live = isLiveDestination
        let startImmediately = !importAddsToQueue
        let dest = importFolder
        var request = variantRequest(plan, action:"register", destination:dest)
        request["includeQueueState"] = true
        importCall(request,as:Registration.self) { registration in
            let m = registration.model
            self.rememberLibrary(dest)
            if let i = self.models.firstIndex(where:{$0.key==m.key}) { self.models[i] = m } else { self.models.append(m) }
            if let hit = self.currentHit, self.bookmarks.contains(where: { $0.resultKey == hit.resultKey }),
               self.localMatches(hit).contains(where: { $0.key == m.key }) {
                self.starOverrides[m.key] = true
                self.bookmarks.removeAll { $0.resultKey == hit.resultKey }
                UserDefaults.standard.set(self.starOverrides, forKey:"modelStars")
                UserDefaults.standard.set(try? JSONEncoder().encode(self.bookmarks),forKey:"catalogBookmarks")
            }
            if live {
                if self.canEdit { self.saveQueuedModels([m.key], at:dest); return }
                self.appendToQueue([m.key])
                self.openDownloads()
            } else {
                self.finishQueuedImport(at:dest)
                if startImmediately && !registration.hadQueue && self.canEdit && self.saved == [m.key] && self.disk.standardizedFileURL == dest.standardizedFileURL {
                    self.preview(auto:true, resumeFirst:m.key)
                }
            }
        }
    }
    private func finishQueuedImport(at destination:URL) {
        if canEdit {
            if destination.resolvingSymlinksInPath().standardizedFileURL.path != folderKey {
                disk = destination
                UserDefaults.standard.set(disk.path, forKey:"lastDownloadFolder")
            }
            do { try reload() } catch { status = error.localizedDescription; return }
            sessionIDs=[]; resetMeters(); stage="idle"
            status = "Очередь сохранена."
            openDownloads()
        } else { editNotice=language.format("Модель в очереди папки %@", destination.path); status = editNotice }
        importing = false
    }
    private var deferredWrites = [(keys:[String], destination:URL)]()
    private func saveQueuedModels(_ keys:[String], at destination:URL) {
        if writing {
            deferredWrites.append((keys, destination))
            return
        }
        importCall(["action":"enqueue", "keys":keys, "disk":destination.path, "live":false],as:[Model].self) { _ in
            self.finishQueuedImport(at:destination)
        }
    }
    var generation = 0
    var priorFinished = [String]()
    private var unconfirmedAppend = [String]()
    private var sentAppend = [String]()
    func appendToQueue(_ keys:[String]) {
        let existing = canEdit ? saved : ids
        let additions = keys.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        if canEdit { saveQueuedModels(additions, at:disk); return }
        unconfirmedAppend.append(contentsOf: additions.filter { !unconfirmedAppend.contains($0) })
        flushAppend()
    }
    private func flushAppend() {
        guard !editBusy, sentAppend.isEmpty, !unconfirmedAppend.isEmpty, stage == "running", !liveIDs.isEmpty else { return }
        sentAppend = unconfirmedAppend
        sendQueueCommand(["append":unconfirmedAppend])
    }
    func changeQueue(_ keys: [String]) {
        if canEdit {
            guard !writing, keys != saved else { return }
            let draft = ids
            let previous = saved
            importCall(["action":"editSavedQueue","disk":disk.path,"live":false,"previous":previous,"keys":keys], as:[Model].self) { _ in
                do {
                    try self.reload()
                    if draft != previous {
                        let removed = Set(previous).subtracting(keys)
                        self.ids = draft.filter { !removed.contains($0) }
                    }
                    self.resetMeters()
                    self.stage = "idle"; self.status = ""; self.editNotice = ""
                    self.sessionIDs = []
                } catch { self.status = error.localizedDescription }
            }
            return
        }
        guard stage == "running", !editBusy, !liveIDs.isEmpty,
              keys.first == liveIDs.first else { return }
        sendQueueCommand(["generation":generation, "pending":keys])
    }
    private func sendQueueCommand(_ request:[String:Any]) {
        guard let pipe = input else { return }
        do {
            var command = try JSONSerialization.data(withJSONObject:request)
            command.append(10)
            editBusy = true
            editNotice = "Проверка изменения…"
            try pipe.write(contentsOf:command)
        } catch {
            sentAppend = []; editBusy = false
            editNotice = error.localizedDescription
        }
    }
    func moveWaiting(_ key:String, by offset:Int) {
        var keys = queueKeys
        guard let i = keys.firstIndex(of:key), keys.indices.contains(i + offset),
              group(for:key) == .queued, group(for:keys[i + offset]) == .queued else { return }
        keys.swapAt(i, i+offset)
        changeQueue(keys)
    }
    @Published var process: Process?
    var input: FileHandle?
    var sessionIDs = [String](), sessionTotal = 0.0, completedOffset = 0.0
    var canEdit: Bool { process == nil }
    init() {
        refreshVolumes()
        let prefs = UserDefaults.standard
        let legacy = prefs.dictionary(forKey: "recommendedFolders") as? [String:String]
        if let path = prefs.string(forKey:"lastDownloadFolder") ?? legacy?["внутренний"],
           FileManager.default.fileExists(atPath:path) { disk = URL(fileURLWithPath:path, isDirectory:true) }
        rememberLibrary(disk)
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName:notification, object:nil, queue:.main) { [weak self] _ in self?.refreshVolumes() })
        }
        let p = Process(), output = Pipe()
        p.executableURL = python
        p.arguments = ["-IB", worker.path,"--catalog"]; p.standardOutput = output
        do {
            try p.run()
            models = try JSONDecoder().decode([Model].self, from: output.fileHandleForReading.readDataToEndOfFile())
            p.waitUntilExit()
            try reload()
            if !saved.isEmpty { openDownloads() }
        } catch { status = language.format("Не удалось открыть реестр: %@", error.localizedDescription) }
    }
    // Match storage_root in the CLI so the GUI can read the same saved queue.
    func modelsFolder(at destination: URL) -> URL {
        let root = destination.appendingPathComponent("Models", isDirectory:true)
        let legacy = destination.appendingPathComponent("Модели", isDirectory:true)
        let files = FileManager.default
        return !files.fileExists(atPath:root.path) && files.fileExists(atPath:legacy.path) ? legacy : root
    }
    var modelsFolder: URL { modelsFolder(at:disk) }
    func libraryDestination(for drive:StorageVolume) -> URL {
        volume(containing:disk)?.id == drive.id ? disk : drive.destination
    }
    func openModelsFolder(on drive:StorageVolume) {
        let destination = libraryDestination(for:drive)
        let folder = modelsFolder(at:destination)
        storageNotice = ""
        do {
            if !drive.readOnly { try prepareModelsFolder(at:destination) }
            let target = FileManager.default.fileExists(atPath:folder.path) ? folder : destination
            if !NSWorkspace.shared.open(target) { throw CocoaError(.fileReadUnknown) }
        } catch { storageNotice = error.localizedDescription }
    }
    private func prepareModelsFolder(at destination: URL) throws {
        let folder = modelsFolder(at:destination)
        do {
            try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:false)
        } catch {
            if (try? folder.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true {
                throw error
            }
        }
    }
    func reload() throws {
        let url = modelsFolder.appendingPathComponent(".download-queue.json")
        if FileManager.default.fileExists(atPath:url.path) {
            savedModels = try JSONDecoder().decode([Model].self,from: Data(contentsOf:url))
        } else { savedModels = [] }
        saved = savedModels.map(\.key)
        ids = saved
        refreshSavedBytes()
        if importing { refreshSearchLocations() }
        if viewingLibrary { refreshInventory() }
    }
    func refreshInventory() {
        let token = UUID(), destination = viewedLibrary
        let drivePage = viewingDrive
        inventoryRequest = token; installed = []; drivePlans = []; scanError = ""; scanning = true
        var bases = Set([destination.resolvingSymlinksInPath().path])
        if drivePage {
            guard let drive = volume(containing:destination) else {
                scanning = false; scanError = language.text("Диск отключён"); return
            }
            if !drive.internalDisk { bases.insert(drive.root.path) }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = knownLibraryBases.union(favoriteStorage.values).union([home.path, drive.destination.path, disk.path])
            for path in candidates where volume(containing:URL(fileURLWithPath:path))?.id == drive.id && FileManager.default.fileExists(atPath:path) {
                bases.insert(URL(fileURLWithPath:path).resolvingSymlinksInPath().path)
            }
        }
        let arguments = drivePage ? ["--drive-library"] + bases.sorted() : ["--inventory",destination.path]
        DispatchQueue.global(qos:.utility).async {
            let result = Result<DriveLibrary,Error> {
                let p = Process(), output = Pipe()
                p.executableURL = python
                p.arguments = ["-IB", worker.path] + arguments
                p.standardOutput = output
                try p.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                if drivePage { return try JSONDecoder().decode(DriveLibrary.self,from:data) }
                return DriveLibrary(installed:try JSONDecoder().decode([InstalledModel].self,from:data),planned:[],errors:[])
            }
            DispatchQueue.main.async {
                guard self.inventoryRequest == token else { return }
                self.scanning = false
                switch result {
                case .success(let library):
                    if drivePage, let drive = self.volume(containing:destination) {
                        self.installed = library.installed.filter { self.volume(containing:URL(fileURLWithPath:$0.path))?.id == drive.id }
                    } else { self.installed = library.installed }
                    self.drivePlans = library.planned.filter { entry in
                        entry.state != "planned" || self.models.first(where:{ $0.key == entry.key }).map(self.starred) == true
                    }
                    self.scanError = library.errors.joined(separator:"\n")
                case .failure(let error): self.scanError = error.localizedDescription
                }
            }
        }
    }
    private func refreshSavedBytes() {
        let token = UUID(), destination = disk
        progressRequest = token
        savedBytes = [:]
        guard !saved.isEmpty else { return }
        DispatchQueue.global(qos:.utility).async {
            let p = Process(), output = Pipe()
            p.executableURL = python
            p.arguments = ["-IB", worker.path, "--queue-progress", destination.path]
            p.standardOutput = output
            guard (try? p.run()) != nil else { return }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let sizes = try? JSONDecoder().decode([String:Int64].self, from:data) else { return }
            DispatchQueue.main.async {
                if self.progressRequest == token { self.savedBytes = sizes }
            }
        }
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func refreshVolumes() {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey,.volumeIsReadOnlyKey,.volumeAvailableCapacityKey,.volumeUUIDStringKey]
        let roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:Array(keys), options:[.skipHiddenVolumes]) ?? []
        volumes = roots.compactMap { root in
            guard root.path == "/" || root.deletingLastPathComponent().path == "/Volumes" else { return nil }
            let values = try? root.resourceValues(forKeys:keys)
            let system = root.path == "/"
            let defaultURL = system ? FileManager.default.homeDirectoryForCurrentUser : root
            let stored = volumeFolders[values?.volumeUUIDString ?? root.path].map { URL(fileURLWithPath:$0, isDirectory:true) }
            let destination = stored.flatMap { FileManager.default.fileExists(atPath:$0.path) ? $0 : nil } ?? defaultURL
            return StorageVolume(root:root, destination:destination, name:values?.volumeLocalizedName ?? root.lastPathComponent,
                                 internalDisk:system, readOnly:!system && values?.volumeIsReadOnly == true,
                                 free:values?.volumeAvailableCapacity.map(Int64.init))
        }.sorted { $0.internalDisk != $1.internalDisk ? $0.internalDisk : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if importing { refreshSearchLocations() }
        if viewingLibrary, volume(containing:viewedLibrary) == nil { refreshInventory() }
    }
    func volume(containing folder: URL) -> StorageVolume? {
        let path = folder.resolvingSymlinksInPath().path
        if let external = volumes.first(where:{ !$0.internalDisk && (path == $0.root.path || path.hasPrefix($0.root.path + "/")) }) { return external }
        return path.hasPrefix("/Volumes/") ? nil : volumes.first(where: { $0.internalDisk })
    }
    func changeFolder(_ url: URL) {
        guard canEdit, !writing else { return }
        disk = url
        UserDefaults.standard.set(url.path, forKey:"lastDownloadFolder")
        sessionIDs = []; sessionTotal = 0; completedOffset = 0
        organizationNotice = ""; resetMeters(); stage = "idle"; status = ""; log = ""
        savedModels = []; saved = []; ids = []; queueSelection = []; choosingQueueModels = false; addingModels = false; focusedDownload = nil
        do { try reload() } catch { status = error.localizedDescription }
        importFolder = url
    }
    func canChangeLibrary(on drive:StorageVolume) -> Bool {
        !drive.readOnly && !writing && (volume(containing:disk)?.id != drive.id || canEdit)
    }
    func pick(on drive:StorageVolume) {
        guard canChangeLibrary(on:drive) else { return }
        let dialog = NSOpenPanel()
        dialog.canChooseFiles = false; dialog.canChooseDirectories = true
        dialog.directoryURL = libraryDestination(for:drive)
        dialog.message = language.format("Выберите папку для библиотеки на диске %@.",drive.name)
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        setLibraryFolder(url, on:drive)
    }
    func setLibraryFolder(_ url:URL, on drive:StorageVolume) {
        guard canChangeLibrary(on:drive), let mounted = volumes.first(where:{ $0.id == drive.id }),
              volume(containing:url)?.id == mounted.id, FileManager.default.fileExists(atPath:url.path) else {
            storageNotice = language.format("Выберите папку для библиотеки на диске %@.",drive.name)
            return
        }
        // The worker appends Models to its base directory. Accept the library itself in the picker too.
        let base = libraryBase(for:url)
        let key = (try? drive.root.resourceValues(forKeys:[.volumeUUIDStringKey]))?.volumeUUIDString ?? drive.id
        volumeFolders[key] = base.path
        UserDefaults.standard.set(volumeFolders, forKey:"volumeFolders")
        if volume(containing:disk)?.id == drive.id && disk.standardizedFileURL.path != base.standardizedFileURL.path {
            changeFolder(base)
        }
        storageNotice = ""
        refreshVolumes()
    }
    func organize() {
        guard canEdit, !writing, !organizing else { return }
        organizing = true
        organizationNotice = ""
        let destination = disk
        importCall(["action":"organizationPlan","disk":destination.path],as:[String].self) { paths in
            self.organizing = false
            guard self.canEdit, self.disk == destination else { return }
            guard !paths.isEmpty else { self.organizationNotice = "Старых загрузок для переноса в этой папке нет"; return }
            let alert = NSAlert()
            alert.messageText = self.language.text("Разложить старые загрузки?")
            alert.informativeText = paths.joined(separator:"\n\n")
            alert.addButton(withTitle:self.language.text("Переместить")); alert.addButton(withTitle:self.language.text("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.organizing = true
            self.importCall(["action":"organize","disk":destination.path],as:[String].self) { moved in
                self.organizing = false
                self.organizationNotice = self.language.format("Перемещено комплектов: %lld", moved.count)
            }
        }
    }
    func selectVisibleModels() {
        let selected = Set(ids)
        ids.append(contentsOf: visibleModels().map(\.key).filter { onSelectedDrive($0) && !selected.contains($0) })
    }
    func resetMeters() {
        progressKey = nil
        current = "Текущая модель"; file = ""; done = 0; total = 0; queueDone = 0; queueTotal = 0; speed = 0
    }
    func toggle(_ key: String) {
        if ids.contains(key) { ids.removeAll { $0 == key } } else { ids.append(key) }
    }
    var canResume: Bool { !saved.isEmpty && ids == saved }
    func downloadModel(_ key: String) {
        guard !writing else { return }
        if !onSelectedDrive(key), let path = favoriteStorage[key] {
            guard FileManager.default.fileExists(atPath:path) else {
                status = language.format("Подключите диск для модели: %@",path)
                return
            }
            let destination = URL(fileURLWithPath:path,isDirectory:true)
            if !canEdit { saveQueuedModels([key], at:destination); return }
            changeFolder(destination)
        }
        if queueKeys.contains(key) {
            if canEdit && group(for:key) == .paused { resumeModel(key) }
            else { openDownloads(focusing:key) }
        } else if canEdit && saved.isEmpty {
            ids = [key]
            preview(auto:true)
        } else if canEdit || stage == "running" {
            appendToQueue([key])
        }
    }
    func pauseModel(_ key: String) {
        guard stage == "running", liveIDs.first == key, !editBusy else { return }
        sendQueueCommand(["pauseModel":key])
    }
    func resumeModel(_ key: String) {
        guard canEdit, !writing, saved.contains(key), group(for:key) == .paused else { return }
        ids = saved
        preview(auto:true, resumeFirst:key)
    }
    func preview(auto: Bool = false, resumeFirst: String? = nil) {
        guard process == nil, !writing, !ids.isEmpty else { return }
        if !saved.isEmpty && saved != ids {
            let alert = NSAlert()
            alert.messageText = language.text("Заменить сохранённую очередь при старте?")
            alert.addButton(withTitle:language.text("Продолжить")); alert.addButton(withTitle:self.language.text("Отмена"))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        let p = Process(), out = Pipe(), cmd = Pipe()
        p.executableURL = python
        p.environment = ProcessInfo.processInfo.environment.merging(["MODEL_DOWNLOADER_LANGUAGE":language.rawValue]) { _, new in new }
        p.arguments = ["-IBu", worker.path]; p.standardInput = cmd; p.standardOutput = out; p.standardError = out
        do {
            var request: [String:Any] = ["disk":disk.path,"ids":ids,"previous":saved,"resume":saved == ids]
            if let resumeFirst { request["resumeFirst"] = resumeFirst }
            var data = try JSONSerialization.data(withJSONObject:request); data.append(10)
            try p.run()
            process = p; input = cmd.fileHandleForWriting
            choosingQueueModels = false; queueSelection = []
            if auto { openDownloads() }
            receivedQueue = false
            resetMeters(); liveIDs = []; editBusy = false; editNotice = ""; log = ""; stage = "preview"; status = "Проверка очереди…"
            try cmd.fileHandleForWriting.write(contentsOf:data)
        } catch { if p.isRunning { p.terminate() }; process = nil; status = error.localizedDescription; return }
        DispatchQueue.global(qos:.utility).async {
            var buffer = Data()
            while true {
                let bytes = out.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                while let end = buffer.firstIndex(of:10) {
                    let line = String(decoding:buffer[..<end],as:UTF8.self)
                    buffer.removeSubrange(...end)
                    DispatchQueue.main.async { self.receive(line, auto:auto) }
                }
            }
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.process = nil; self.input = nil; self.speed = 0
                if self.stage == "stopping" { self.stage = "paused"; self.status = "Загрузка приостановлена" }
                else if !["complete","error","paused"].contains(self.stage) {
                    self.stage = "error"; self.status = "Процесс остановлен. Подробности в журнале."
                }
                let selection = self.ids
                do { try self.reload(); if self.saved.isEmpty && self.stage != "complete" { self.ids = selection } }
                catch { self.status = error.localizedDescription }
                let additions = self.unconfirmedAppend.filter { !self.saved.contains($0) }
                self.unconfirmedAppend = []; self.sentAppend = []
                self.editBusy = false
                if !additions.isEmpty { self.saveQueuedModels(additions, at:self.disk) }
            }
        }
    }
    func receive(_ line: String, auto: Bool) {
        guard line.hasPrefix("@@"), let data = String(line.dropFirst(2)).data(using:.utf8),
              let e = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {
            if !line.isEmpty { log = String((log + line + "\n").suffix(24000)) }; return
        }
        func n(_ k:String) -> Double { (e[k] as? NSNumber)?.doubleValue ?? 0 }
        switch e["event"] as? String {
        case "ready":
            guard stage != "stopping" else { return }
            let continues = ids == saved && !sessionIDs.isEmpty && sessionIDs.suffix(ids.count).elementsEqual(ids)
            priorFinished = continues ? Array(sessionIDs.dropLast(ids.count)) : []
            completedOffset = continues ? max(0,sessionTotal - n("total")) : 0
            if !continues { sessionIDs = ids; sessionTotal = n("total") }
            queueTotal = n("total") + completedOffset; queueDone = n("done") + completedOffset
            file = ""; stage = "ready"; status = "Очередь проверена"
            if auto { start(showDownloads: false) }
        case "queue":
            guard let keys = e["pending"] as? [String], let finished = e["finished"] as? [String] else { return }
            if (viewingDrive && liveIDs != keys) || (viewingLibrary && liveIDs.contains(where:finished.contains)) {
                refreshInventory()
            }
            if importing && liveIDs.contains(where:finished.contains) { refreshSearchLocations() }
            receivedQueue = true
            liveIDs = keys
            ids = priorFinished + finished + keys
            sessionIDs = ids
            sessionTotal = n("total") + completedOffset
            queueTotal = sessionTotal
            queueDone = n("done") + completedOffset
            generation = Int(n("generation"))
            if e["ack"] as? Bool == true {
                unconfirmedAppend.removeAll { sentAppend.contains($0) }; sentAppend = []
                editBusy = false
                editNotice = "Изменения сохранены"
            }
            flushAppend()
        case "editError":
            unconfirmedAppend.removeAll { sentAppend.contains($0) }
            sentAppend = []
            editBusy = false
            editNotice = e["message"] as? String ?? "Не удалось изменить очередь"
            flushAppend()
        case "reconnect":
            guard stage != "stopping" else { return }
            speed = 0
            file = e["file"] as? String ?? ""
            status = language.format("Ожидание связи · автоповтор через %lld с", Int(n("delay")))
        case "progress":
            guard stage != "stopping" else { return }
            progressKey = e["key"] as? String
            current = e["model"] as? String ?? ""; file = e["file"] as? String ?? ""
            done = n("done"); total = n("total"); queueDone = n("queueDone") + completedOffset; queueTotal = n("queueTotal") + completedOffset; speed = n("speed")
            status = ["network":"Скачивание","verify":"Проверка контрольной суммы","assemble":"Сборка и проверка GGUF","prepare":"Подготовка модели"][e["phase"] as? String ?? ""] ?? ""
        case "complete": stage = "complete"; status = "Очередь завершена"; queueDone = queueTotal; file = ""; sessionIDs = []
        case "pausing": stage = "stopping"; status = "Остановка…"; editNotice = ""; speed = 0
        case "paused": stage = "paused"; status = "Загрузка приостановлена"
        case "error": stage = "error"; status = e["message"] as? String ?? "Ошибка"
        default: break
        }
    }
    func start(showDownloads: Bool = true) {
        guard stage == "ready" else { return }
        if showDownloads && !importing { openDownloads() }
        do { try input?.write(contentsOf:Data("start \(language.rawValue)\n".utf8)); stage = "running"; status = "Начинается загрузка…" }
        catch { status = error.localizedDescription }
    }
    func pause() {
        guard let p = process, p.isRunning else { return }
        stage = "stopping"; status = "Остановка…"; speed = 0
        if kill(-p.processIdentifier,SIGINT) != 0 { p.interrupt() }
    }
}
private enum Layout {
    static let edge: CGFloat = 18
    static let gap: CGFloat = 8
    static let section: CGFloat = 12
}

private extension View {
    func modelListRow() -> some View {
        // Plain macOS lists supply an eight-point cell margin on both sides.
        let inset = Layout.edge - 8
        return self.padding(.horizontal, inset)
            .alignmentGuide(.listRowSeparatorLeading) { _ in inset }
            .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width - inset }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}

struct Meter: View {
    let language: AppLanguage
    let title: String, symbol: String, done: Double, total: Double, speed: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: symbol).lineLimit(1).help(title)
                Spacer()
                Text(total > 0 ? String(format: "%.1f%%", 100 * min(done, total) / total) : "—")
                    .fontWeight(.semibold).monospacedDigit()
            }
            ProgressView(value: min(done, total), total: max(1, total))
                .accessibilityLabel(title)
            let amount = total > 0 ? language.fileSize(done) + " / " + language.fileSize(total) : language.text("Подготовка")
            let time = language.format("Осталось %@", eta(total - done, speed, language))
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(amount).fixedSize()
                    Spacer(minLength: Layout.gap)
                    if speed > 0 { Text(time).fixedSize() }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(amount)
                    if speed > 0 { Text(time) }
                }
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct DownloadsList: View {
    @ObservedObject var app: Downloads

    private func row(_ key: String, position: Int, keys: [String], group: DownloadGroup) -> some View {
        let model = app.queueModel(key)
        let measured = app.progressKey == key && (group == .active || group == .paused)
        let bytes = measured ? Int64(app.done) : app.savedBytes[key]
        let total = model?.size ?? 0
        return HStack(spacing: 12) {
            Text(String(position + 1)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.language.text(model?.name ?? key)).fontWeight(.medium).lineLimit(2)
                HStack(spacing: Layout.gap) {
                    if group == .active {
                        let phase = app.language.text(measured ? app.status : "Подготовка модели")
                        Text(phase).lineLimit(1).help(phase)
                    } else if let quant = model?.quant {
                        Text(app.language.variantLabel(quant)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if total > 0 {
                        let size = app.language.fileSize(Double(total))
                        let amount = group != .queued ? bytes : nil
                        Text(amount.map { app.language.fileSize(Double($0)) + " / " + size } ?? size)
                            .monospacedDigit().fixedSize()
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if group != .queued, let bytes, total > 0 {
                    ProgressView(value: Double(min(bytes, total)), total: Double(total))
                        .accessibilityLabel(app.language.text(model?.name ?? key))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if group == .active || group == .paused {
                let active = group == .active
                let action = app.language.text(active ? "Пауза" : "Продолжить")
                let title = app.language.format(active ? "Приостановить загрузку %@" : "Продолжить загрузку %@", model?.name ?? key)
                Button {
                    if active { app.pauseModel(key) } else { app.resumeModel(key) }
                } label: {
                    Label(action, systemImage:active ? "pause.fill" : "play.fill")
                        .labelStyle(.titleAndIcon).fixedSize()
                }.buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel(title).help(title)
                    .disabled(active ? app.stage != "running" || app.liveIDs.first != key : !app.canEdit)
            }
            if group != .active && (app.canEdit || app.stage == "running" && !app.liveIDs.isEmpty) {
                if group == .queued && keys.count > 1 {
                    Button { app.moveWaiting(key, by:-1) } label: {
                        Label("Переместить выше", systemImage:"chevron.up")
                    }.disabled(position == 0 || app.group(for:keys[position - 1]) != .queued)
                    Button { app.moveWaiting(key, by:1) } label: {
                        Label("Переместить ниже", systemImage:"chevron.down")
                    }.disabled(position + 1 == keys.count || app.group(for:keys[position + 1]) != .queued)
                }
                Button { app.changeQueue(keys.filter { $0 != key }) } label: {
                    Label("Убрать из очереди", systemImage:"minus.circle")
                }.help("Убрать из очереди")
            }
        }.labelStyle(.iconOnly).buttonStyle(.borderless)
            .padding(.vertical, 8).frame(minHeight: 44).modelListRow()
            .accessibilityElement(children:.contain)
            .disabled(app.editBusy || app.writing)
    }

    var body: some View {
        let keys = app.queueKeys
        if keys.isEmpty {
            ContentUnavailableView("Нет загрузок", systemImage:"tray", description:Text("Добавьте модели из браузера или избранного."))
                .frame(maxWidth:.infinity, maxHeight:.infinity)
        } else {
            ScrollViewReader { scroll in
              List(selection:$app.focusedDownload) {
                ForEach(DownloadGroup.allCases, id: \.self) { group in
                    let entries = keys.enumerated().filter { app.group(for:$0.element) == group }
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries, id: \.element) { position, key in
                                row(key, position:position, keys:keys, group:group).id(key).tag(key)
                            }
                        } header: {
                            Text(app.language.text(group.rawValue) + " · " + String(entries.count)).modelListRow()
                        }
                    }
                }
              }.listStyle(.plain)
                  .onChange(of:app.focusedDownload, initial:true) { _, key in
                      if let key { scroll.scrollTo(key, anchor:.center) }
                  }
            }
        }
    }
}

struct SidebarItem: View {
    let title: String, symbol: String, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.gap) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).lineLimit(2)
            }
                .fontWeight(selected ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct StarButton: View {
    @Environment(\.locale) private var locale
    private var language: AppLanguage { locale.identifier.hasPrefix("en") ? .en : .ru }
    let name: String, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? "star.fill" : "star")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
        }.buttonStyle(.borderless)
            .accessibilityLabel(language.format(selected ? "Убрать из избранного %@" : "В избранное %@", name))
            .help(language.text(selected ? "Убрать из избранного" : "Сохранить в избранное"))
    }
}

private final class BrowserVariants: ObservableObject {
    @Published var expanded = false
    @Published var plan: ImportPlan?
    @Published var error = ""
}
struct DiscoveryRow: View {
    @ObservedObject var app: Downloads
    let hit: SearchHit
    @StateObject private var variants = BrowserVariants()
    private var isLeaf: Bool { !["lm","lm-page","ollama"].contains(hit.kind ?? "") }

    private func open(_ plan:ImportPlan, index:Int) {
        app.cancelLookup(); app.currentHit = hit; app.selectedProvider = hit.source ?? app.provider
        app.reference = hit.id; app.importFolder = app.disk; app.importMessage = ""; app.importing = true
        app.showPlan(plan,choosing:index)
        if app.importPurposes.isEmpty { app.importPurposes = hit.purposes ?? [] }
    }
    private func statusRow(_ row:VariantLocation) -> some View {
        HStack {
            Text(verbatim:app.language.variantLabel(row.detail) + " · " + app.locationText(row)).font(.caption)
                .fixedSize(horizontal:false,vertical:true)
            Spacer()
            let local = app.volume(containing:URL(fileURLWithPath:row.disk)) != nil
            if ["installed","partial"].contains(row.state) && local {
                Button("В Finder"){app.openLocation(row)}.buttonStyle(.borderless)
            } else if ["queued","active","paused"].contains(row.state) && local {
                Button("К загрузкам"){app.openLocation(row)}.buttonStyle(.borderless)
                    .disabled(row.disk != app.disk.resolvingSymlinksInPath().path && !app.canEdit)
            }
        }
    }
    var body: some View {
        let known = variants.plan.map { app.classifiedLocations(for:hit,plan:$0) } ?? app.locations(for:hit)
        VStack(alignment:.leading,spacing:5) {
        HStack(spacing: 10) {
            Button {
                if !app.importing { app.importFolder = app.disk }
                app.importing = true
                app.selectHit(hit)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.id).fontWeight(.medium).lineLimit(2)
                    HStack(spacing: 10) {
                        Text(hit.source ?? app.provider)
                        if let n = hit.downloads { Label(n.formatted(.number.notation(.compactName).locale(app.language.locale)), systemImage: "arrow.down.to.line").help("Скачивания по данным каталога") }
                        if let n = hit.likes { Label(n.formatted(.number.notation(.compactName).locale(app.language.locale)), systemImage: "hand.thumbsup").help("Звёзды сообщества") }
                        if let n = hit.trending, app.ranking == "trending" { Label(n.formatted(.number.locale(app.language.locale)), systemImage: "chart.line.uptrend.xyaxis").help("Рейтинг трендов каталога") }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(app.writing)
            StarButton(name:hit.id, selected:app.bookmarked(hit)) { app.toggleBookmark(hit) }
        }
        if !variants.expanded { ForEach(known) { row in statusRow(row) } }
        if app.importing && isLeaf {
            Button {
                variants.expanded.toggle()
            } label: {
                Label("Варианты",systemImage:variants.expanded ? "chevron.down" : "chevron.right")
            }.buttonStyle(.borderless)
            VStack(alignment:.leading,spacing:5) {
                if variants.expanded {
                if let plan = variants.plan {
                    ForEach(known.filter { row in !plan.options.contains { app.locationMatches(row,option:$0,plan:plan) } }) { row in
                        if let rev = row.rev, rev != plan.rev {
                            Text(app.language.format("Другая ревизия · %@",String(rev.prefix(12)))).font(.caption).foregroundStyle(.secondary)
                        }
                        statusRow(row)
                    }
                    ForEach(plan.options.indices,id:\.self) { index in
                        let option = plan.options[index]
                        let matches = known.filter { app.locationMatches($0,option:option,plan:plan) }
                        Button {
                            open(plan,index:index)
                        } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(app.language.variantLabel(option.label)).fixedSize(horizontal:false,vertical:true)
                                Text(([app.language.format("Основные файлы %@",app.language.fileSize(Double(option.size)))] + (matches.isEmpty
                                    ? [app.language.text(app.indexingLocations ? "Проверка дисков…" : app.failedLocationBases.isEmpty ? "Доступен · Диск не назначен" : "Размещение неизвестно")]
                                    : matches.map(app.locationText))).joined(separator:" · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical,3).disabled(app.writing)
                    }
                } else if !variants.error.isEmpty {
                    Text(variants.error).font(.callout)
                } else { ProgressView().controlSize(.small) }
                }
            }.font(.callout)
            .task(id:variants.expanded) {
                guard variants.expanded, variants.plan == nil else { return }
                variants.error = ""
                let request: [String:Any]
                if hit.kind == "ms" || hit.kind == "tag" {
                    request = ["action":"platformPlan","source":hit.source ?? app.provider,"id":hit.id,"snapshot":hit.snapshot ?? ""]
                } else {
                    request = ["action":"inspect","url":hit.url ?? "https://huggingface.co/" + hit.id]
                }
                do {
                    let result = try await app.readPreview(request,as:ImportPlan.self)
                    if !Task.isCancelled { variants.plan = result }
                } catch {
                    if !Task.isCancelled { variants.error = error.localizedDescription }
                }
            }
        }
        }.padding(.vertical,6).frame(minHeight:44).accessibilityElement(children:.contain)
    }
}

private struct BrowserSearchField: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    let fieldLabel: LocalizedStringKey
    let clearLabel: LocalizedStringKey
    var focusRequest = 0
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField(placeholder, text:$text)
                .textFieldStyle(.plain).focused($focused)
                .onSubmit(submit).accessibilityLabel(Text(fieldLabel))
                .onChange(of:focusRequest, initial:true) { _, request in
                    if request != 0 { DispatchQueue.main.async { focused = true } }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                    submit()
                } label: {
                    Image(systemName:"xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width:22, height:22).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text(clearLabel)).help(Text(clearLabel))
            }
        }
        .padding(.leading, 7).padding(.trailing, 3).frame(minHeight: 24)
        .background(Color(nsColor:.textBackgroundColor), in:RoundedRectangle(cornerRadius:5))
        .overlay {
            RoundedRectangle(cornerRadius:5)
                .strokeBorder(focused ? Color.accentColor : Color(nsColor:.separatorColor),
                              lineWidth:focused ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
}

struct ModelBrowser: View {
    @ObservedObject var app: Downloads
    private var pathKey: String {
        [app.plan?.repo ?? "", app.plan?.rev ?? "", String(app.variant), app.extra,
         app.importPurposes.joined(separator:"|"), app.importFolder.path].joined(separator:"\n")
    }
    private func submit() {
        let query = app.searchText.trimmingCharacters(in:.whitespacesAndNewlines)
        if query.lowercased().hasPrefix("https://") { app.link = query; app.inspectLink() }
        else { app.search() }
    }
    private func back() {
        app.planningFavorite = false
        app.cancelLookup()
        if app.plan != nil { app.plan = nil; app.importPath = ""; app.importMessage = ""; if app.hits.isEmpty { app.searchText = ""; app.search() } }
        else { app.backLevel() }
    }
    private var hasFilters: Bool {
        !app.appliedAuthor.isEmpty || !app.searchPurpose.isEmpty || (app.provider == "Hugging Face" && !app.searchFormat.isEmpty)
    }
    private func resetFilters() {
        app.author = ""; app.searchPurpose = ""; app.searchFormat = ""
        app.search()
    }
    private func filterChip(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action:remove) {
            HStack(spacing:4) {
                Text(label).lineLimit(1)
                Image(systemName:"xmark.circle.fill")
            }
        }.controlSize(.small).help(label)
            .accessibilityLabel(app.language.format("Убрать фильтр %@",label))
    }
    @ViewBuilder private var filterChips: some View {
        if !app.appliedAuthor.isEmpty {
            filterChip(app.language.format("Автор: %@",app.appliedAuthor)) { app.author = ""; app.search() }
        }
        if !app.searchPurpose.isEmpty {
            filterChip(app.language.text(app.searchPurpose)) { app.searchPurpose = ""; app.search() }
        }
        if app.provider == "Hugging Face" && !app.searchFormat.isEmpty {
            filterChip(app.searchFormat.uppercased()) { app.searchFormat = ""; app.search() }
        }
    }
    private var filters: some View {
        VStack(alignment:.leading,spacing:Layout.gap) {
            HStack {
                BrowserSearchField(text:$app.searchText, placeholder:"Название модели или ссылка",
                                   fieldLabel:"Поиск моделей", clearLabel:"Очистить поиск", focusRequest:app.searchFocusRequest, submit:submit)
                Button("Найти", action:submit).disabled(app.writing)
                if app.lookup != nil {
                    Button { app.cancelLookup() } label: { Label("Отменить запрос",systemImage:"xmark.circle") }
                        .labelStyle(.iconOnly).help("Отменить запрос")
                }
            }
            HStack {
                Picker("Каталог",selection:$app.provider) { ForEach(providers,id:\.self){ Text(app.language.text($0)).tag($0) } }
                    .labelsHidden().accessibilityLabel("Каталог")
                    .onChange(of:app.provider) { _, _ in
                        if !app.rankings.contains(app.ranking) { app.ranking = "downloads" }
                        else { app.search() }
                    }
                Picker("Сортировка",selection:$app.ranking) {
                    ForEach(app.rankings,id:\.self){ key in Text(app.language.text(rankingNames[key] ?? key)).tag(key) }
                }.labelsHidden().accessibilityLabel("Сортировка").onChange(of:app.ranking) { _, _ in app.search() }
                Button {
                    app.showFilters.toggle()
                    if !app.showFilters && app.author.trimmingCharacters(in:.whitespacesAndNewlines) != app.appliedAuthor { submit() }
                } label: { Label("Фильтры",systemImage:"line.3.horizontal.decrease") }
            }
            if app.showFilters {
                let authorField = HStack(spacing:6) {
                    Text("Автор").fixedSize()
                    BrowserSearchField(text:$app.author, placeholder:"", fieldLabel:"Автор",
                                       clearLabel:"Очистить фильтр автора", submit:submit)
                }
                let selectors = HStack(spacing: Layout.gap) {
                    Picker("Назначение",selection:Binding(get:{app.searchPurpose}, set:{app.searchPurpose = $0; app.search()})) {
                        Text("Все назначения").tag("")
                        ForEach(purposeOptions,id:\.self){Text(app.language.text($0)).tag($0)}
                    }.labelsHidden().accessibilityLabel("Назначение")
                    if app.provider == "Hugging Face" {
                        Picker("Формат",selection:Binding(get:{app.searchFormat}, set:{app.searchFormat = $0; app.search()})) {
                            Text("Все форматы").tag(""); Text("GGUF").tag("gguf"); Text("MLX").tag("mlx")
                        }.labelsHidden().accessibilityLabel("Формат")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Layout.gap) { authorField.frame(minWidth: 120); selectors.fixedSize() }
                    VStack(alignment: .leading, spacing: Layout.gap) { authorField; selectors }
                }
            } else if hasFilters {
                ViewThatFits(in:.horizontal) {
                    HStack { filterChips }.fixedSize()
                    VStack(alignment:.leading, spacing:4) { filterChips }
                }
            }
        }.padding(.horizontal,Layout.edge).padding(.bottom,Layout.section).disabled(app.writing)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:0,pinnedViews:[.sectionHeaders]) {
                if !app.browseTitle.isEmpty {
                    Button { back() } label: { Label(app.language.format("Назад · %@",app.browseTitle),systemImage:"chevron.left") }
                        .padding(.vertical,6)
                }
                let grouped = Dictionary(grouping:app.resultGroups) { $0.first?.source ?? app.provider }
                ForEach(providers.dropFirst(),id:\.self) { provider in
                    if let groups = grouped[provider] {
                        Section {
                            ForEach(groups,id:\.[0].groupKey) { group in
                                ForEach(group,id:\.resultKey) { hit in
                                    DiscoveryRow(app:app,hit:hit)
                                    Divider()
                                }
                            }
                        } header: {
                            Text(provider).font(.caption.bold()).foregroundStyle(.secondary)
                                .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6)
                                .background(.background)
                        }
                    }
                }
                if app.nextCursor != nil {
                    Button("Показать ещё"){app.search(more:true)}.disabled(app.busy).padding(.vertical,6)
                }
                ForEach(Array(Set(app.searchWarnings)).sorted(),id:\.self){ Text($0).font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal,Layout.edge)
        }
    }

    @ViewBuilder private func detail(_ plan: ImportPlan) -> some View {
        let option = plan.options[app.variant]
        let installed = app.installedSelection(plan)
        let target = installed?.path ?? (app.importPath.isEmpty ? app.modelsFolder(at:app.importFolder).path : app.importPath)
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                Button(action: back) { Label("К результатам",systemImage:"chevron.left") }
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text(plan.repo).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(app.selectedProvider).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let favorite = app.models.first { $0.key == app.importVariantKey && app.starred($0) }
                    StarButton(name:option.label,selected:favorite != nil){
                        if let favorite { app.toggleStar(favorite) } else { app.chooseFavoriteDrive() }
                    }.disabled(app.busy)
                }
                Divider()
                Picker("Комплект",selection:$app.variant){
                    ForEach(plan.options.indices,id:\.self){ i in
                        Text(app.language.variantLabel(plan.options[i].label) + " · " + app.language.fileSize(Double(plan.options[i].size))).tag(i)
                    }
                }.onChange(of:app.variant){ _,i in app.configureVariant(plan,for:i) }
                let choices = app.projectorChoices(plan,for:app.variant)
                if !choices.isEmpty {
                    Picker("Проектор для изображений",selection:Binding(get:{app.extra},set:app.selectProjector)) {
                        Text("Только текст").tag("")
                        ForEach(choices,id:\.name){ f in
                            Text(f.name + " · " + app.language.fileSize(Double(f.size))).tag(f.name)
                        }
                    }
                    Text(app.extra.isEmpty ? "Для анализа изображений выберите проектор." : "Проектор для анализа изображений включён в размер загрузки.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if option.files.contains(where: { $0.lowercased().contains("mmproj") }) {
                    Text("Проектор входит в выбранный комплект.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(option.label.lowercased().hasSuffix(".gguf") && app.importPurposes.contains("Анализ изображений")
                         ? "Для этого варианта в репозитории не найден отдельный проектор."
                         : "Этот комплект загружается без отдельного проектора.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Menu(app.language.format("Назначение · %@", app.importPurposes.isEmpty ? app.language.text("Не указано") : app.importPurposes.map(app.language.text).joined(separator:", "))) {
                    ForEach(purposeOptions,id:\.self) { label in
                        Toggle(app.language.text(label),isOn:Binding(get:{app.importPurposes.contains(label)},set:{
                            if $0 { app.importPurposes.append(label) } else { app.importPurposes.removeAll{$0 == label} }
                        }))
                    }
                }
                DisclosureGroup(app.language.format("Файлы комплекта · %lld", option.files.count + app.selectedProjectorFiles.count)) {
                    VStack(alignment:.leading) {
                        ForEach(option.files + app.selectedProjectorFiles,id:\.self){Text($0).font(.caption).textSelection(.enabled)}
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                if !app.planningFavorite {
                    Divider()
                    HStack {
                        Text("Сохранить в").font(.headline)
                        Spacer()
                        Menu(app.volume(containing:app.importFolder)?.name ?? app.diskName(app.importFolder.path)) {
                            ForEach(app.volumes) { v in Button(v.name){app.chooseImportDestination(app.libraryDestination(for:v))}.disabled(v.readOnly) }
                            Divider(); Button("Другая папка…"){app.chooseImportFolder()}
                        }.fixedSize()
                    }
                    if let free = app.importFreeBytes {
                        Text(app.language.format("Свободно %@",app.language.fileSize(Double(free))))
                            .font(.callout).monospacedDigit()
                        if installed == nil && (app.importRequiredBytes ?? app.importSize) > free {
                            Text("На выбранном диске недостаточно места для загрузки.").font(.callout)
                        }
                    }
                    Text(verbatim:target).id(target)
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(.horizontal, Layout.edge).padding(.bottom, Layout.section)
        }
        .onAppear {app.updateImportPath()}
        .onChange(of:pathKey){ _,_ in app.updateImportPath() }
        Divider()
        HStack {
            let remaining = installed == nil ? app.importRemainingBytes : 0
            if let remaining, remaining < app.importSize {
                Text(app.language.format("Осталось скачать %@",app.language.fileSize(Double(remaining))))
                    .monospacedDigit().fontWeight(.semibold)
            } else {
                Text(app.language.fileSize(Double(app.importSize))).monospacedDigit().fontWeight(.semibold)
            }
            Spacer()
            if app.planningFavorite {
                Button("Выбрать диск для избранного…"){app.chooseFavoriteDrive()}.buttonStyle(.borderedProminent).disabled(app.busy)
            } else if let installed {
                Button("В Finder"){app.openLocation(installed)}.buttonStyle(.borderedProminent)
                    .disabled(app.volume(containing:app.importFolder) == nil || app.failedLocationBases.contains(installed.disk))
            } else {
                Button(app.language.text(app.importAddsToQueue ? "Добавить в очередь" : "Скачать")){app.enqueueImport()}.buttonStyle(.borderedProminent)
                    .disabled(app.busy || app.importPath.isEmpty || app.editBusy ||
                              app.volume(containing:app.importFolder)?.readOnly != false ||
                              (!app.canEdit && app.stage != "running" && app.importFolder.standardizedFileURL == app.disk.standardizedFileURL))
            }
        }.padding(.horizontal, Layout.edge).padding(.vertical, Layout.section)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if let plan=app.plan { detail(plan) }
            else {
                filters
                Divider()
                if app.didSearch && app.hits.isEmpty && !app.busy && app.nextCursor == nil && app.importMessage.isEmpty && app.searchWarnings.isEmpty {
                    HStack {
                        Text("Модели не найдены").foregroundStyle(.secondary)
                        if hasFilters { Button("Сбросить фильтры", action:resetFilters) }
                    }.padding(.horizontal, Layout.edge).padding(.vertical, Layout.section)
                }
                results
            }
            if !app.failedLocationBases.isEmpty {
                let names = Set(app.failedLocationBases.map(app.diskName)).sorted().joined(separator:", ")
                Text(app.language.format("Не удалось проверить хранилище: %@",names))
                    .font(.caption).padding(.horizontal,Layout.edge)
            }
            if app.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(app.language.text(app.writing ? "Сохранение…" : "Запрос к каталогу…")).font(.callout)
                }.padding(.horizontal,Layout.edge).padding(.vertical,6)
            }
            if !app.importMessage.isEmpty {
                Text(app.language.text(app.importMessage)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal,Layout.edge).padding(.vertical,6)
            }
        }
        .onAppear { app.refreshSearchLocations() }
    }
}
struct Content: View {
    @ObservedObject var app: Downloads
    private var showingQueue: Bool { !app.importing && app.section == "Загрузки" }
    private var visibleModels: [Model] { app.visibleModels(addingToQueue:app.addingModels) }
    private var selectedAdditions: [String] { app.queueSelection.filter { !app.queueKeys.contains($0) } }
    private var additionsSize: Int64 {
        let keys = Set(selectedAdditions)
        return app.models.reduce(0) { $0 + (keys.contains($1.key) ? $1.size : 0) }
    }

    private func modelSelection(_ key:String) -> Binding<Bool> {
        Binding(get:{ app.choosingQueueModels ? app.queueSelection.contains(key) : app.ids.contains(key) }, set:{ selected in
            if app.choosingQueueModels {
                if selected && !app.queueSelection.contains(key) { app.queueSelection.append(key) }
                else if !selected { app.queueSelection.removeAll { $0 == key } }
            } else if selected != app.ids.contains(key) { app.toggle(key) }
        })
    }

    private func openCollection(_ section: String) {
        app.planningFavorite = false
        app.addingModels = false
        app.importing = false
        app.choosingQueueModels = app.stage == "running"
        app.section = section
        if section == "Скачанные модели" { app.refreshInventory() }
    }

    private func openCatalog() {
        openCollection("Избранное")
        app.choosingQueueModels = true
        app.addingModels = true
    }

    private var sidebar: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("Библиотека").font(.headline).padding(.horizontal,8).padding(.bottom,5)
            SidebarItem(title:app.language.text("Браузер моделей"),symbol:"safari",selected:app.importing){app.openImport()}
            SidebarItem(title:app.language.text("Избранное"),symbol:"star",
                        selected:!app.importing && app.section == "Избранное"){openCollection("Избранное")}
            SidebarItem(title:app.language.text("Загрузки"),symbol:"arrow.down.circle",selected:showingQueue) {
                app.openDownloads()
            }
            SidebarItem(title:app.language.text("Скачанные модели"),symbol:"internaldrive",
                        selected:!app.importing && app.section == "Скачанные модели"){openCollection("Скачанные модели")}
            Divider().padding(.vertical,8)
            HStack {
                Text("Хранилище").font(.headline)
                Spacer()
                Button {app.refreshVolumes()} label:{ Label("Обновить диски",systemImage:"arrow.clockwise") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Обновить диски")
            }.padding(.horizontal,8)
            ScrollView {
                VStack(alignment:.leading,spacing:4) {
                    ForEach(app.volumes){ volume in
                        VStack(alignment:.leading,spacing:0) {
                            SidebarItem(title:volume.name,symbol:volume.internalDisk ? "internaldrive" : "externaldrive",
                                        selected:app.viewingDrive && app.volume(containing:app.viewedLibrary)?.id == volume.id) {
                                    app.viewLibrary(on:volume)
                                }
                            if let free=volume.free {
                                Text(app.language.format(volume.readOnly ? "Только чтение · %@" : "Свободно %@", app.language.fileSize(Double(free))))
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading,34).padding(.bottom,4)
                            }
                        }
                    }
                }
            }
            Spacer(minLength:0)
            Divider().padding(.vertical, 4)
            SidebarItem(title:app.language.text("Настройки"), symbol:"gearshape", selected:false) {
                NSApp.sendAction(#selector(Delegate.openSettings), to:nil, from:nil)
            }
        }.padding(12).frame(width:208).background(.thinMaterial)
    }

    private func catalogAction(_ model: Model) -> some View {
        let position = app.onSelectedDrive(model.key) ? app.queueKeys.firstIndex(of:model.key) : nil
        let title: String
        if let position {
            switch app.group(for:model.key) {
            case .paused: title = app.language.text(app.canEdit ? "Продолжить" : "На паузе")
            case .active: title = app.language.text("Скачивание")
            default: title = app.language.format("В очереди · №%lld",position + 1)
            }
        } else if app.onSelectedDrive(model.key) && !app.canEdit && app.ids.contains(model.key) {
            title = app.language.text("Завершено")
        } else {
            title = app.language.text(app.canEdit && app.saved.isEmpty ? "Скачать" : "Добавить в очередь")
        }
        return Button(title) { app.downloadModel(model.key) }
            .buttonStyle(.bordered).controlSize(.small).fixedSize()
            .disabled(app.writing || app.onSelectedDrive(model.key) && position == nil && !app.canEdit && (app.stage != "running" || app.ids.contains(model.key)))
            .accessibilityLabel(title + " · " + model.name)
    }

    private func favoriteRow(_ model:Model) -> some View {
        let currentDrive = app.onSelectedDrive(model.key)
        return HStack(spacing:Layout.gap) {
            Toggle(isOn:modelSelection(model.key)) { Text(model.name) }.labelsHidden().toggleStyle(.checkbox)
                .disabled(!currentDrive || (app.choosingQueueModels ? app.queueKeys.contains(model.key) || !app.canEdit && app.ids.contains(model.key) : !app.canEdit))
                .accessibilityLabel(app.language.text(model.name))
            VStack(alignment:.leading,spacing:3) {
                Text(app.language.text(model.name)).fontWeight(.medium).lineLimit(2)
                Text(model.labels.map(app.language.text).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                if model.personal == true, let repo = model.repo {
                    Text((model.source ?? "Hugging Face") + " · " + repo).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(app.language.variantLabel(model.quant)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(app.language.fileSize(Double(model.size))).monospacedDigit().frame(width:84,alignment:.trailing)
            if !app.addingModels { catalogAction(model) }
            Button { app.chooseFavoriteDrive(model) } label: { Label("Выбрать диск…", systemImage:"externaldrive") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Выбрать диск…")
                .disabled(app.writing || app.queueKeys.contains(model.key))
            StarButton(name:model.name,selected:app.starred(model)){app.toggleStar(model)}
        }.frame(minHeight:46).modelListRow().accessibilityElement(children:.contain)
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Назначение модели", selection: $app.purposeFilter) {
                    ForEach(["Все назначения"] + purposeOptions + ["Не указано"], id: \.self) { Text(app.language.text($0)).tag($0) }
                }.labelsHidden().accessibilityLabel("Назначение модели").fixedSize()
                Spacer()
                Menu("Выбор") {
                    Button("Выбрать показанные") {
                        if app.choosingQueueModels {
                            let selected = Set(app.queueSelection)
                            app.queueSelection.append(contentsOf: visibleModels.map(\.key).filter { app.onSelectedDrive($0) && !selected.contains($0) && !app.queueKeys.contains($0) && (app.canEdit || !app.ids.contains($0)) })
                        } else { app.selectVisibleModels() }
                    }.disabled(visibleModels.isEmpty)
                    Button("Снять выбор") {
                        if app.choosingQueueModels { app.queueSelection = [] } else { app.ids = [] }
                    }
                }.fixedSize().disabled(!app.choosingQueueModels && !app.canEdit)
            }.padding(.horizontal, Layout.edge).padding(.bottom, Layout.section)
            Divider()
            let links = app.section == "Избранное" ? app.bookmarks.filter {
                app.purposeFilter == "Все назначения" || ($0.purposes ?? []).contains(app.purposeFilter)
            } : []
            if visibleModels.isEmpty && links.isEmpty {
                VStack(spacing:10) {
                    let allFavoritesQueued = app.addingModels && app.purposeFilter == "Все назначения" && app.visibleModels().contains(where:{ app.onSelectedDrive($0.key) && app.queueKeys.contains($0.key) })
                    Text(allFavoritesQueued ? "Все избранные модели уже в очереди" : "Нет моделей для выбора").font(.headline)
                    if app.purposeFilter != "Все назначения" { Button("Сбросить фильтр"){app.purposeFilter="Все назначения"} }
                    if !app.addingModels { Button("Открыть браузер моделей"){app.openImport()} }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                List {
                    ForEach(links,id:\.resultKey){ hit in DiscoveryRow(app:app,hit:hit).modelListRow() }
                    let groups = Dictionary(grouping:visibleModels) { app.favoriteStorage[$0.key] ?? "" }
                    ForEach(groups.keys.sorted { a,b in
                        if a.isEmpty || b.isEmpty { return !a.isEmpty && b.isEmpty }
                        return a.localizedStandardCompare(b) == .orderedAscending
                    }, id:\.self) { path in
                        Section {
                            ForEach(groups[path] ?? []) { model in favoriteRow(model) }
                        } header: {
                            Text(path.isEmpty ? app.language.text("Диск не назначен") : app.volume(containing:URL(fileURLWithPath:path))?.name ?? path)
                                .help(path).modelListRow()
                        }
                    }
                }.listStyle(.plain)
            }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(app.viewingDrive ? app.diskName(app.viewedLibrary.path) : app.language.text(app.addingModels ? "Добавить модели" : app.importing ? "Браузер моделей" : app.section)).font(.title2).fontWeight(.semibold)
                Spacer()
                if app.viewingDrive {
                    Button("Обновить"){app.refreshInventory()}.disabled(app.scanning)
                }
                if showingQueue {
                    Button { openCatalog() } label: {
                        Label("Добавить модели…", systemImage: "plus")
                    }.disabled(!app.canEdit && app.stage != "running" || app.writing)
                }
            }.padding(.horizontal, Layout.edge).padding(.vertical, Layout.section)
            if app.addingModels {
                Picker("Источник моделей", selection:Binding(get:{app.importing}, set:{ search in
                    if search { app.openImport(fromPicker:true) } else { app.importing = false; app.planningFavorite = false }
                })) {
                    Text("Избранное").tag(false)
                    Text("Поиск в каталогах").tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Источник моделей")
                    .padding(.horizontal,Layout.edge).padding(.bottom,Layout.gap)
            }
            if app.importing {
                ModelBrowser(app:app)
            } else if app.viewingLibrary {
                if !app.viewingDrive {
                    HStack {
                        Text(app.diskName(app.viewedLibrary.path)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Обновить"){app.refreshInventory()}.disabled(app.scanning)
                    }.padding(.horizontal,Layout.edge).padding(.bottom,Layout.gap)
                }
                Divider()
                if !app.scanError.isEmpty {
                    Text(app.scanError).foregroundStyle(.secondary).textSelection(.enabled).padding(.horizontal,Layout.edge)
                }
                if app.scanning {
                    ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)
                } else if app.installed.isEmpty && app.drivePlans.isEmpty && app.scanError.isEmpty {
                    Text(app.language.text(app.viewingDrive ? "На этом диске пока нет запланированных или скачанных моделей" : "На этом диске пока нет скачанных моделей"))
                        .foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    List {
                        if !app.installed.isEmpty {
                            Section {
                                ForEach(app.installed) { item in
                                    HStack {
                                        VStack(alignment:.leading,spacing:4) {
                                            Text(item.name).fontWeight(.medium).lineLimit(2)
                                            Text(app.language.variantLabel(item.detail)).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(app.language.fileSize(Double(item.size))).monospacedDigit()
                                        Button("В Finder"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:item.path)])}
                                            .buttonStyle(.borderless).help(item.path)
                                    }.frame(minHeight:44).modelListRow()
                                }
                            } header: { if app.viewingDrive { Text("Скачанные модели") } }
                        }
                        if !app.drivePlans.isEmpty {
                            Section("Запланировано") {
                                ForEach(app.drivePlans) { item in
                                    HStack {
                                        VStack(alignment:.leading,spacing:4) {
                                            Text(item.name).fontWeight(.medium).lineLimit(2)
                                            Text([app.language.variantLabel(item.detail),app.language.text(app.planStatus(item))].filter{!$0.isEmpty}.joined(separator:" · "))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(app.language.fileSize(Double(item.size))).monospacedDigit()
                                    }.frame(minHeight:44).modelListRow()
                                }
                            }
                        }
                    }.listStyle(.plain)
                }
            } else if showingQueue {
                Divider()
                DownloadsList(app: app)
                if !app.editNotice.isEmpty {
                    Text(app.language.text(app.editNotice)).font(.callout).padding(.horizontal, Layout.edge).padding(.vertical, 5)
                }
            } else {
                catalog
                if app.choosingQueueModels || !app.ids.isEmpty {
                    Divider()
                    HStack {
                        let count = app.choosingQueueModels ? selectedAdditions.count : app.ids.count
                        let size = app.choosingQueueModels ? additionsSize : app.selectedSize
                        Text("Выбрано: \(count) · \(app.language.fileSize(Double(size)))").monospacedDigit()
                        Spacer()
                        if app.choosingQueueModels {
                            if app.stage != "running" {
                                Button("К загрузкам") { app.openDownloads() }
                            }
                            Button("Добавить в конец очереди") {
                                app.appendToQueue(selectedAdditions)
                                app.openDownloads()
                            }.buttonStyle(.borderedProminent)
                                .disabled(selectedAdditions.isEmpty || app.editBusy || app.writing)
                        } else if app.stage == "ready" {
                            Text("Осталось скачать \(app.language.fileSize(max(0, app.queueTotal - app.queueDone)))")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.padding(.horizontal, Layout.edge).padding(.vertical, 9)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logButton: some View {
        Button { app.showLog.toggle() } label: {
            Label(app.language.text(app.showLog ? "Скрыть журнал" : "Журнал"), systemImage:"text.alignleft")
        }
    }
    private var transferPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            let key = app.queueKeys.first
            let pausedInBrowser = app.importing && app.canEdit && app.stage != "error" && key.map { app.group(for:$0) == .paused } == true
            if !showingQueue && (app.stage == "running" || app.stage == "stopping" || pausedInBrowser), let key {
                let model = app.queueModel(key)
                let bytes = app.progressKey == key ? Int64(app.done) : app.savedBytes[key]
                HStack(spacing:Layout.gap) {
                    Text(model?.name ?? app.language.text("Текущая модель")).lineLimit(1).truncationMode(.middle)
                    if let bytes, let size = model?.size, size > 0 {
                        Text((Double(min(bytes,size)) / Double(size)).formatted(.percent.precision(.fractionLength(0)).locale(app.language.locale))).monospacedDigit()
                    }
                    Spacer(minLength:0)
                    if pausedInBrowser {
                        Button("Продолжить") { app.resumeModel(key) }.disabled(app.writing)
                    } else {
                        Button("Пауза") { app.pauseModel(key) }
                            .disabled(app.stage != "running" || app.liveIDs.first != key || app.editBusy)
                    }
                    Button("Загрузки") { app.openDownloads(focusing:key) }
                    logButton
                }
            } else {
                if showingQueue && app.queueTotal > 0 {
                    Meter(language:app.language, title:app.language.text("Вся очередь"), symbol:"list.number",
                          done:app.queueDone, total:app.queueTotal, speed:app.speed)
                }
                if !app.status.isEmpty {
                    Text(app.language.text(app.status) + (app.file.isEmpty ? "" : " · " + app.file))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    if app.canEdit && showingQueue && !app.saved.isEmpty {
                        let paused = app.saved.contains { app.group(for:$0) == .paused }
                        Button(app.language.text(paused ? "Продолжить очередь" : "Начать загрузку")) {
                            app.ids = app.saved
                            app.preview(auto:true)
                        }.buttonStyle(.borderedProminent).disabled(app.writing)
                    } else if app.canEdit && app.section == "Избранное" && !app.importing && !app.choosingQueueModels {
                        Button(app.language.text(app.canResume ? "Продолжить очередь" : "Скачать")) {
                            app.preview(auto:true)
                        }.buttonStyle(.borderedProminent).disabled(app.ids.isEmpty || app.writing)
                        if !app.ids.isEmpty { Button("Предпросмотр") { app.preview() }.disabled(app.writing) }
                    } else if app.stage == "ready" {
                        Button("Начать загрузку") { app.start() }.buttonStyle(.borderedProminent)
                    }
                    if app.stage == "preview" || app.stage == "ready" { Button("Вернуться к выбору") { app.pause() } }
                    if showingQueue && app.speed > 0 {
                        Text(app.language.format("%.1f МБ/с", app.speed / 1e6)).font(.callout).monospacedDigit()
                    }
                    Spacer()
                    logButton
                }
            }
            if app.showLog {
                ScrollView([.vertical, .horizontal]) {
                    Text(app.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 80)
                    .padding(Layout.gap)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
        }.padding(.horizontal, Layout.edge).padding(.vertical, Layout.section)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                workspace
                Divider()
                transferPanel
            }
        }.frame(minWidth: 760, minHeight: 590)
            .sheet(item:$app.favoriteLocation) { location in
                FavoriteLocationSheet(app:app, location:location)
            }
            .environment(\.locale, app.language.locale)

    }
}
private struct FavoriteLocationSheet: View {
    @ObservedObject var app: Downloads
    @ObservedObject var location: FavoriteLocation
    @Environment(\.dismiss) private var dismiss
    private var drives: [StorageVolume] { app.volumes.filter { !$0.readOnly } }
    private var drive: StorageVolume? { drives.first { $0.id == location.selected } }

    private var folder: URL? {
        guard let drive, location.resolvedDrive == drive.destination else { return nil }
        return location.preview
    }

    private var drivePicker: some View {
        HStack(spacing:12) {
            Image(systemName:drive?.internalDisk == true ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size:21,weight:.medium)).foregroundStyle(Color.accentColor)
                .frame(width:40,height:40)
                .background(Color.accentColor.opacity(0.12),in:RoundedRectangle(cornerRadius:10))
                .accessibilityHidden(true)
            VStack(alignment:.leading,spacing:3) {
                Text("Диск").font(.headline)
                if let free = drive?.free {
                    Text(app.language.format("Свободно %@",app.language.fileSize(Double(free))))
                        .font(.callout).foregroundStyle(.primary.opacity(0.72))
                }
            }
            Spacer(minLength:12)
            Picker("Диск",selection:$location.selected) {
                if drive == nil { Text("Выберите подключённый диск").tag("") }
                ForEach(drives) { volume in Text(volume.name).tag(volume.id) }
            }.labelsHidden().accessibilityLabel("Диск").disabled(drives.isEmpty)
        }
        .padding(12)
        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12))
        .overlay { RoundedRectangle(cornerRadius:12).strokeBorder(.separator,lineWidth:1).allowsHitTesting(false) }
    }

    private func folderPreview(_ path:URL, on drive:StorageVolume) -> some View {
        let parents = drive.folders(to:path.deletingLastPathComponent())
        let name = path.lastPathComponent.replacingOccurrences(
            of:#" \[[0-9]+ [·-] [0-9a-f]{12}\]$"#, with:"", options:.regularExpression)
        return VStack(alignment:.leading,spacing:10) {
            HStack(alignment:.top,spacing:10) {
                Image(systemName:"folder.fill").symbolRenderingMode(.hierarchical)
                    .font(.title3).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text(parents.joined(separator:"  ›  ")).font(.callout).foregroundStyle(.primary.opacity(0.72))
                    Text(name).font(.headline).fixedSize(horizontal:false,vertical:true)
                }
            }
            Divider()
            DisclosureGroup("Полный путь",isExpanded:$location.expanded) {
                HStack(alignment:.top,spacing:8) {
                    Text(path.path).font(.system(.callout,design:.monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(path.path,forType:.string)
                    } label: { Label("Скопировать путь",systemImage:"doc.on.doc") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Скопировать путь")
                }.padding(.top,6)
            }.font(.callout)
        }
        .padding(14).frame(maxWidth:.infinity,alignment:.leading)
        .background(.quaternary.opacity(0.50),in:RoundedRectangle(cornerRadius:12))
    }

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:18) {
                Text("Место хранения модели").font(.title2.weight(.semibold))
                drivePicker
                VStack(alignment:.leading,spacing:6) {
                    Text("Папка модели").font(.subheadline.weight(.medium)).foregroundStyle(.primary.opacity(0.72))
                    if let drive, let folder {
                        folderPreview(folder,on:drive)
                    } else if !location.error.isEmpty {
                        Text(location.error).fixedSize(horizontal:false,vertical:true)
                    } else if drive != nil {
                        ProgressView().controlSize(.small).frame(maxWidth:.infinity,minHeight:72)
                    }
                }
            }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            Divider()
            HStack(spacing:8) {
                Spacer()
                Button("Отмена"){ dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить"){
                    guard let drive, folder != nil else { return }
                    app.saveFavorite(location.model,at:drive.destination); dismiss()
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(folder == nil || app.writing)
            }.controlSize(.large).padding(.horizontal,22).padding(.vertical,12)
        }.frame(width:464)
        .task(id:drive?.destination) {
            location.preview = nil; location.resolvedDrive = nil; location.error = ""
            guard let drive else { return }
            do {
                let folder = try await app.favoriteFolder(location.model, at:drive.destination)
                guard !Task.isCancelled else { return }
                location.preview = folder; location.resolvedDrive = drive.destination
            } catch {
                if !Task.isCancelled { location.error = error.localizedDescription }
            }
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var app: Downloads
    let updater: SPUUpdater
    private func driveRow(_ drive:StorageVolume) -> some View {
        let destination = app.libraryDestination(for:drive)
        let folder = app.modelsFolder(at:destination)
        let selected = app.volume(containing:app.disk)?.id == drive.id
        return VStack(alignment:.leading,spacing:6) {
            HStack(spacing:8) {
                Image(systemName:drive.internalDisk ? "internaldrive" : "externaldrive")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
                Text(drive.name).fontWeight(.semibold)
                if selected {
                    Label("Выбран",systemImage:"checkmark").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let free = drive.free {
                    Text(app.language.format("Свободно %@",app.language.fileSize(Double(free))))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(folder.path).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:8) {
                Button("Изменить…"){app.pick(on:drive)}.disabled(!app.canChangeLibrary(on:drive))
                Button("В Finder"){app.openModelsFolder(on:drive)}
                if drive.readOnly { Text("Только чтение").font(.caption).foregroundStyle(.secondary) }
            }.controlSize(.small)
        }.padding(.vertical,3)
    }
    var body: some View {
        Form {
            Section("Оформление") {
                Picker("Тема", selection: $app.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(app.language.text(theme.title)).tag(theme)
                    }
                }.pickerStyle(.segmented)
                Picker("Язык интерфейса", selection: $app.language) {
                    Text(verbatim: "Русский").tag(AppLanguage.ru)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
            }
            Section("Обновления") {
                Toggle("Проверять обновления автоматически", isOn:Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { enabled in
                        app.objectWillChange.send()
                        updater.automaticallyChecksForUpdates = enabled
                    }))
            }
            Section("Подключённые диски") {
                ForEach(app.volumes) { drive in driveRow(drive) }
                if !app.storageNotice.isEmpty { Text(app.storageNotice).font(.callout) }
            }
            Section(app.language.format("Обслуживание библиотеки · %@",app.volume(containing:app.disk)?.name ?? app.disk.lastPathComponent)) {
                VStack(alignment: .leading, spacing: Layout.gap) {
                    Button("Разложить старые загрузки…") { app.organize() }
                        .disabled(!app.canEdit || app.writing || app.organizing)
                    Text("Посмотреть, какие загрузки можно перенести в английские папки по назначению моделей.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true)
                    if !app.canEdit {
                        Text("Перенос доступен после остановки очереди.").font(.callout)
                    } else if app.organizing {
                        ProgressView("Проверка папок…").controlSize(.small)
                    } else if !app.organizationNotice.isEmpty {
                        Text(app.language.text(app.organizationNotice)).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }.formStyle(.grouped)
            .environment(\.locale, app.language.locale)
    }
}

final class Delegate:NSObject,NSApplicationDelegate,NSWindowDelegate,SPUUpdaterDelegate,NSMenuItemValidation {
    var window:NSWindow!
    let app = Downloads()
    private var settingsWindow: NSWindow?
    private var observers = Set<AnyCancellable>()
    private lazy var updates = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    private var pendingInstall: (() -> Void)?
    private var installWhenFinished = false
    private var updatePromptOpen = false
    private var libraryBusy: Bool { !app.canEdit || app.writing || app.organizing }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard libraryBusy else { return false }
        pendingInstall = installHandler
        presentUpdateChoice()
        return true
    }

    private func presentUpdateChoice() {
        guard !updatePromptOpen else { return }
        let alert = NSAlert()
        alert.messageText = app.language.text("Обновление BentoDisk готово")
        alert.informativeText = app.language.text("Приложение перезапустится, когда завершатся загрузки и операции с библиотекой.")
        alert.addButton(withTitle:app.language.text("Обновить после завершения очереди"))
        alert.addButton(withTitle:app.language.text("Позже")).keyEquivalent = "\u{1b}"
        updatePromptOpen = true
        alert.beginSheetModal(for:window) { response in
            self.updatePromptOpen = false
            self.installWhenFinished = response == .alertFirstButtonReturn
            self.finishDeferredUpdate()
        }
    }

    private func finishDeferredUpdate() {
        guard installWhenFinished, !libraryBusy, app.saved.isEmpty else { return }
        installPendingUpdate()
    }
    private func installPendingUpdate() {
        let install = pendingInstall
        pendingInstall = nil
        installWhenFinished = false
        install?()
    }
    @objc func checkForUpdates(_ sender: Any?) {
        if pendingInstall == nil { updates.checkForUpdates(sender) }
        else if libraryBusy { presentUpdateChoice() }
        else { installPendingUpdate() }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(checkForUpdates(_:)) else { return true }
        item.title = app.language.text(pendingInstall == nil ? "Проверить обновления…" : "Установить обновление…")
        return !updatePromptOpen && (pendingInstall != nil || updates.updater.canCheckForUpdates)
    }

    @objc func openSettings() {
        app.refreshVolumes()
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x:0, y:0, width:560, height:600),
                                 styleMask: [.titled,.closable,.resizable], backing:.buffered, defer:false)
            let view = NSHostingView(rootView:PreferencesView(app:app, updater:updates.updater))
            view.sizingOptions = []
            panel.contentView = view
            panel.contentMinSize = NSSize(width:420, height:310)
            panel.isReleasedWhenClosed = false
            panel.title = app.language.text("Настройки")
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window { settingsWindow?.close() }
    }
    @objc func browseModels() { window.makeKeyAndOrderFront(nil); app.focusSearch() }
    @objc func showDownloads() { app.openDownloads(); window.makeKeyAndOrderFront(nil) }
    private func configureMenu(_ language: AppLanguage) {
        let main = NSMenu()
        let appMenu = NSMenu()
        let first = main.addItem(withTitle:"",action:nil,keyEquivalent:"")
        first.submenu = appMenu
        appMenu.addItem(withTitle:language.text("Проверить обновления…"), action:#selector(checkForUpdates(_:)), keyEquivalent:"").target = self
        let settings = appMenu.addItem(withTitle:language.text("Настройки…"), action:#selector(openSettings), keyEquivalent:",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:language.text("Завершить загрузчик"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let edit = NSMenu(title:language.text("Правка"))
        main.addItem(withTitle:language.text("Правка"),action:nil,keyEquivalent:"").submenu = edit
        for (name, selector, key) in [("Вырезать","cut:","x"),("Скопировать","copy:","c"),
                                      ("Вставить","paste:","v"),("Выбрать всё","selectAll:","a")] {
            edit.addItem(withTitle:language.text(name),action:Selector(selector),keyEquivalent:key)
        }
        let search = edit.addItem(withTitle:language.text("Браузер моделей"),action:#selector(browseModels),keyEquivalent:"f")
        search.target = self
        let view = NSMenu(title:language.text("Вид"))
        main.addItem(withTitle:view.title,action:nil,keyEquivalent:"").submenu = view
        let downloads = view.addItem(withTitle:language.text("Загрузки"),action:#selector(showDownloads),keyEquivalent:"l")
        downloads.keyEquivalentModifierMask = [.command,.option]
        downloads.target = self
        NSApp.mainMenu = main
    }
    func applicationDidFinishLaunching(_ notification:Notification) {
        let view = NSHostingView(rootView:Content(app:app))
        view.sizingOptions = []
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:820),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Загрузчик моделей"; window.contentView = view; window.delegate=self
        window.contentMinSize = NSSize(width:760,height:590)
        if let frame = NSScreen.main?.visibleFrame {
            window.setContentSize(NSSize(width:min(980,frame.width),height:min(820,frame.height - 40)))
        }
        app.$theme.sink { NSApp.appearance = $0.appearance }.store(in:&observers)
        app.$language.sink { [weak self] language in
            self?.configureMenu(language)
            self?.window.title = language.text("Загрузчик моделей")
            self?.settingsWindow?.title = language.text("Настройки")
        }.store(in:&observers)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        _ = updates
        Publishers.CombineLatest4(app.$process, app.$writing, app.$organizing, app.$saved)
            .receive(on:DispatchQueue.main)
            .sink { [weak self] _ in self?.finishDeferredUpdate() }.store(in:&observers)
    }
    func applicationWillTerminate(_ notification:Notification){ app.cancelLookup(); app.pause() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = Delegate()
application.delegate = delegate
application.run()
