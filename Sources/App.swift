import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: Hashable {
    case all, unfiled, collection(UUID)
}

@main
struct ZhiyeApp: App {
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup("纸页文献库") {
            LibraryView(store: store)
                .frame(minWidth: 1000, minHeight: 650)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.flush() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.flush() }
        }
        .defaultSize(width: 1340, height: 850)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @State private var section: LibrarySection? = .all
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var sortNewest = true
    @State private var showImporter = false
    @State private var dropTarget = false
    @State private var collectionDialog = false
    @State private var editingCollection: Collection?
    @State private var collectionName = ""
    @State private var editingPaper: Paper?
    @State private var removingPaper: Paper?
    @State private var deletingCollection: Collection?

    private var selected: Paper? { store.data.papers.first { $0.id == selectedID } }
    private var destination: UUID? {
        if case .collection(let id) = section { return id }; return nil
    }
    private var sectionTitle: String {
        switch section {
        case .collection(let id): return store.data.collections.first { $0.id == id }?.name ?? "分类"
        case .unfiled: return "未分类"
        default: return "全部文献"
        }
    }
    private var visible: [Paper] {
        store.data.papers.filter { paper in
            let matches: Bool
            switch section {
            case .collection(let id): matches = paper.collectionID == id
            case .unfiled: matches = paper.collectionID == nil
            default: matches = true
            }
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return matches && (search.isEmpty || paper.title.localizedStandardContains(search)
                || paper.notes.localizedStandardContains(search) || paper.originalName.localizedStandardContains(search))
        }.sorted { sortNewest ? $0.addedAt > $1.addedAt : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 270)
        } content: {
            paperList
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 500)
        } detail: {
            reader
        }
        .tint(Color(red: 0.18, green: 0.45, blue: 0.4))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: { Label("导入 PDF", systemImage: "plus") }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(store.importing || !store.available)
                    .help("导入 PDF（⌘O），文件将复制到文献库")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): let target = destination; Task { await store.importPDFs(urls, into: target) }
            case .failure(let error): store.issue = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $collectionDialog) { collectionEditor }
        .sheet(item: $editingPaper) { paper in
            PaperEditor(paper: paper) { title, notes in store.updatePaper(paper.id, title: title, notes: notes) }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.issue != nil }, set: { if !$0 { store.issue = nil } })) {
            Button("知道了", role: .cancel) { store.issue = nil }
        } message: { Text(store.issue ?? "") }
        .alert("移除这条文献记录？", isPresented: Binding(get: { removingPaper != nil }, set: { if !$0 { removingPaper = nil } })) {
            Button("取消", role: .cancel) { removingPaper = nil }
            Button("移除记录", role: .destructive) {
                if let paper = removingPaper { store.removePaper(paper.id); if selectedID == paper.id { selectedID = nil } }
                removingPaper = nil
            }
        } message: { Text("分类和备注将从列表移除。原始 PDF 和文献库中的 PDF 副本都会保留。") }
        .alert("删除分类？", isPresented: Binding(get: { deletingCollection != nil }, set: { if !$0 { deletingCollection = nil } })) {
            Button("取消", role: .cancel) { deletingCollection = nil }
            Button("删除分类", role: .destructive) {
                if let category = deletingCollection { store.deleteCollection(category.id); section = .unfiled }
                deletingCollection = nil
            }
        } message: { Text("该分类中的文献会移到“未分类”。") }
        .onChange(of: section) { _ in selectedID = nil }
        .onChange(of: query) { _ in if !visible.contains(where: { $0.id == selectedID }) { selectedID = nil } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("纸页").font(.title3.weight(.semibold))
                    Text("本地文献库").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            List(selection: $section) {
                Label { sidebarLabel("全部文献", count: store.data.papers.count) } icon: { Image(systemName: "square.stack") }
                    .tag(LibrarySection.all)
                Label { sidebarLabel("未分类", count: store.data.papers.filter { $0.collectionID == nil }.count) } icon: { Image(systemName: "tray") }
                    .tag(LibrarySection.unfiled)
                Section {
                    ForEach(store.data.collections) { category in
                        Label { sidebarLabel(category.name, count: store.data.papers.filter { $0.collectionID == category.id }.count) } icon: { Image(systemName: "folder") }
                            .tag(LibrarySection.collection(category.id))
                            .contextMenu {
                                Button("重命名") { editingCollection = category; collectionName = category.name; collectionDialog = true }
                                Button("删除分类…", role: .destructive) { deletingCollection = category }
                            }
                    }
                } header: {
                    HStack {
                        Text("我的分类")
                        Spacer()
                        Button { newCollection() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("新建分类")
                            .disabled(!store.available)
                    }
                }
            }.listStyle(.sidebar)
            Divider()
            Button { NSWorkspace.shared.open(store.root) } label: { Label("打开文献库文件夹", systemImage: "internaldrive") }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }

    private func sidebarLabel(_ name: String, count: Int) -> some View {
        HStack { Text(name).lineLimit(1); Spacer(); Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
    }

    private var paperList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(sectionTitle).font(.title2.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Menu { Button("最近导入") { sortNewest = true }; Button("标题排序") { sortNewest = false } }
                        label: { Image(systemName: "arrow.up.arrow.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("文献排序")
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索标题、文件名或备注", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }.padding(18)
            Divider()
            if visible.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: query.isEmpty ? "doc.badge.plus" : "magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "把文献放进来" : "没有匹配的文献").font(.headline)
                    Text(query.isEmpty ? "拖入 PDF，或点击导入\n文件会安全复制到本地文献库" : "试试其他标题、文件名或备注关键词")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if query.isEmpty { Button("导入 PDF…") { showImporter = true }.disabled(store.importing || !store.available) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(visible) { paper in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "doc.richtext").font(.system(size: 25, weight: .light)).foregroundStyle(.tint).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(paper.title).font(.system(size: 13, weight: .medium)).lineLimit(3)
                                Text("\(paper.pageCount) 页 · \(paper.addedAt.formatted(date: .numeric, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !paper.notes.isEmpty { Text(paper.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }.padding(.vertical, 9).tag(paper.id)
                            .contextMenu { paperActions(paper) }
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack(spacing: 6) {
                if store.importing { ProgressView().controlSize(.mini) }
                Text(store.notice ?? "\(visible.count) 篇文献 · 支持拖入 PDF")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(4).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty, !store.importing, store.available else { return false }
            let target = destination; Task { await store.importPDFs(pdfs, into: target) }; return true
        } isTargeted: { dropTarget = $0 }
    }

    @ViewBuilder private var reader: some View {
        if let paper = selected {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(paper.title).font(.headline).lineLimit(1)
                        Text("\(paper.pageCount) 页 · 已记录到第 \(paper.lastPage + 1) 页").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu { moveActions(paper) } label: { Label("分类", systemImage: "folder") }.fixedSize()
                    Button { editingPaper = paper } label: { Image(systemName: "square.and.pencil") }.help("编辑标题和备注")
                    Menu { paperActions(paper) } label: { Image(systemName: "ellipsis.circle") }.fixedSize()
                }.padding(16)
                Divider()
                PDFReader(url: store.url(for: paper), initialPage: paper.lastPage,
                          onPageChange: { store.rememberPage(paper.id, page: $0) },
                          onFailure: { store.issue = $0 })
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "book.pages").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(.tint)
                Text("留一处安静读文献的地方").font(.title2.weight(.medium))
                Text("选择一篇文献开始阅读\n分类、备注与阅读位置都保存在这台 Mac 上")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                HStack(spacing: 18) {
                    Label("本地保存", systemImage: "internaldrive")
                    Label("无需账号", systemImage: "person.crop.circle")
                }.font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder private func moveActions(_ paper: Paper) -> some View {
        Button("未分类") { store.movePaper(paper.id, to: nil) }
        ForEach(store.data.collections) { category in Button(category.name) { store.movePaper(paper.id, to: category.id) } }
    }

    @ViewBuilder private func paperActions(_ paper: Paper) -> some View {
        Button("编辑标题和备注…") { editingPaper = paper }
        Menu("移动到分类") { moveActions(paper) }
        Divider()
        Button("在访达中显示 PDF") { NSWorkspace.shared.activateFileViewerSelecting([store.url(for: paper)]) }
        Button("用默认应用打开") { NSWorkspace.shared.open(store.url(for: paper)) }
        Divider()
        Button("移除记录…", role: .destructive) { removingPaper = paper }
    }

    private func newCollection() { editingCollection = nil; collectionName = ""; collectionDialog = true }
    private var collectionEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingCollection == nil ? "新建分类" : "重命名分类").font(.title3.bold())
            TextField("例如：研究方法、待读、毕业论文", text: $collectionName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { collectionDialog = false }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let category = editingCollection { store.renameCollection(category.id, name: collectionName) }
                    else if let id = store.addCollection(collectionName) { section = .collection(id) }
                    collectionDialog = false
                }.keyboardShortcut(.defaultAction).disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 400)
    }
}

struct PaperEditor: View {
    let paper: Paper
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    init(paper: Paper, onSave: @escaping (String, String) -> Void) {
        self.paper = paper; self.onSave = onSave
        _title = State(initialValue: paper.title); _notes = State(initialValue: paper.notes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("文献信息").font(.title3.bold())
            Text("标题").font(.caption).foregroundStyle(.secondary)
            TextField("文献标题", text: $title).textFieldStyle(.roundedBorder)
            Text("阅读备注").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $notes).font(.body).frame(height: 160).border(Color.secondary.opacity(0.2))
            Text("原文件：\(paper.originalName)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(title, notes); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 500)
    }
}
