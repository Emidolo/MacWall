import SwiftUI
import UniformTypeIdentifiers
import MacWallKit

struct LibraryView: View {
    @ObservedObject private var library = Library.shared
    @State private var search = ""
    @State private var filter: WallpaperProject.Kind?
    @State private var showDownload = false
    @State private var editing: Wallpaper?
    @State private var errorMessage: String?

    private var filtered: [Wallpaper] {
        library.items.filter { w in
            (filter == nil || w.project.kind == filter)
                && (search.isEmpty || w.title.localizedCaseInsensitiveContains(search) || w.id.contains(search))
        }
    }

    var body: some View {
        ScrollView {
            if library.items.isEmpty {
                ContentUnavailableView("No wallpapers yet", systemImage: "photo.on.rectangle",
                                       description: Text("Download one from the Steam Workshop, or import a folder or .zip copied from Wallpaper Engine."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(filtered) { w in WallpaperCard(wallpaper: w) { editing = w } }
            }
            .padding()
        }
        .searchable(text: $search, prompt: "Search wallpapers")
        .toolbar {
            Picker("Type", selection: $filter) {
                Text("All").tag(WallpaperProject.Kind?.none)
                Text("Video").tag(WallpaperProject.Kind?.some(.video))
                Text("Web").tag(WallpaperProject.Kind?.some(.web))
                Text("Scene").tag(WallpaperProject.Kind?.some(.scene))
            }
            .pickerStyle(.segmented)
            Button("Import…", systemImage: "square.and.arrow.down", action: importPanel)
            Button("Download…", systemImage: "icloud.and.arrow.down") { showDownload = true }
        }
        .sheet(isPresented: $showDownload) { DownloadView() }
        .sheet(item: $editing) { PropertiesView(wallpaper: $0) }
        .alert("Import failed", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .frame(minWidth: 720, minHeight: 460)
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.message = "Choose wallpaper folders (containing project.json) or .zip files"
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls { try library.importItem(at: url) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let onEditProperties: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    private var isActive: Bool { settings.assignments.values.contains(wallpaper.id) }
    private var playable: Bool { [.video, .web, .scene].contains(wallpaper.project.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: wallpaper.previewURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, .tint).padding(6)
                }
            }
            HStack(spacing: 6) {
                Text(wallpaper.title).lineLimit(1).font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if wallpaper.project.kind == .scene, case let missing = SceneSupport.unsupported(wallpaper.folder), !missing.isEmpty {
                    Text("Partial").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.25), in: Capsule())
                        .help("Rendered without: " + missing.joined(separator: ", "))
                }
                Text(wallpaper.project.kind.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if playable { settings.assign(wallpaper.id, display: nil) } }
        .contextMenu {
            Button("Set on All Displays") { settings.assign(wallpaper.id, display: nil) }.disabled(!playable)
            if NSScreen.screens.count > 1 {
                ForEach(NSScreen.screens, id: \.uuid) { screen in
                    Button("Set on \(screen.localizedName)") { settings.assign(wallpaper.id, display: screen.uuid) }.disabled(!playable)
                }
            }
            Button("Properties…", action: onEditProperties)
                .disabled(!WallpaperProperties(json: wallpaper.project.propertiesJSON).hasEditable)
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([wallpaper.folder]) }
            Button("Delete", role: .destructive) { Library.shared.delete(wallpaper) }
        }
        .help(playable ? "Double-click to set as wallpaper; right-click for more." : "Application wallpapers aren't supported on macOS.")
    }
}

struct DownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var steam = SteamCMD.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var input = ""
    @State private var username = AppSettings.shared.steamUsername
    @State private var secret = ""
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download from Steam Workshop").font(.headline)
            if steam.locate() == nil {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("steamcmd is not installed.").bold()
                        Text("Install it with Homebrew, then run `steamcmd +quit` once in Terminal so it can finish updating:")
                        Text("brew install steamcmd").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        TextField("Or path to steamcmd", text: $settings.steamcmdPath)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            TextField("Steam username", text: $username).textContentType(.username)
            TextField("Workshop URL or ID", text: $input)
            Text("You must own Wallpaper Engine on this Steam account. Your password goes straight to steamcmd and is never stored.")
                .font(.caption).foregroundStyle(.secondary)

            switch steam.prompt {
            case .password:
                SecureField("Steam password", text: $secret).onSubmit(sendSecret)
            case .guardCode:
                TextField("Steam Guard code", text: $secret).onSubmit(sendSecret)
            case .mobileConfirm:
                Label("Approve the sign-in in the Steam Mobile app.", systemImage: "iphone")
            case nil:
                EmptyView()
            }

            if steam.busy {
                if let p = steam.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
            }
            if !steam.status.isEmpty || result != nil {
                Text(result ?? steam.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }

            HStack {
                Spacer()
                if steam.busy {
                    Button("Cancel") { steam.cancel() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                if steam.prompt == .password || steam.prompt == .guardCode {
                    Button("Continue", action: sendSecret).keyboardShortcut(.defaultAction).disabled(secret.isEmpty)
                } else {
                    Button("Download", action: start).keyboardShortcut(.defaultAction)
                        .disabled(steam.busy || username.isEmpty || WorkshopID.parse(input) == nil || steam.locate() == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func sendSecret() {
        guard !secret.isEmpty else { return }
        steam.answer(secret)
        secret = ""
    }

    private func start() {
        guard let id = WorkshopID.parse(input) else { return }
        settings.steamUsername = username
        result = nil
        Task {
            do {
                let items = try await steam.download(id: id, user: username)
                result = "Added \(items.map(\.title).joined(separator: ", "))."
            } catch {
                result = error.localizedDescription
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var library = Library.shared

    var body: some View {
        Form {
            Section("Playback") {
                LabeledContent("Volume") {
                    Slider(value: $settings.volume, in: 0...1) { EmptyView() } minimumValueLabel: {
                        Image(systemName: "speaker.slash")
                    } maximumValueLabel: { Image(systemName: "speaker.wave.3") }
                }
                Picker("Frame rate limit", selection: $settings.fpsLimit) {
                    Text("Unlimited").tag(0)
                    ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Quality", selection: $settings.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Section("Displays") {
                Toggle("Same wallpaper on all displays", isOn: $settings.mirror)
                if !settings.mirror {
                    ForEach(NSScreen.screens, id: \.uuid) { screen in
                        Picker(screen.localizedName, selection: Binding(
                            get: { settings.assignments[screen.uuid] ?? "" },
                            set: { settings.assign($0, display: screen.uuid) })) {
                            Text("None").tag("")
                            ForEach(library.items) { Text($0.title).tag($0.id) }
                        }
                    }
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                TextField("steamcmd path (optional)", text: $settings.steamcmdPath, prompt: Text(SteamCMD.searchPaths[0]))
                TextField("Wallpaper Engine assets folder (optional)", text: $settings.weAssetsPath, prompt: Text("…/wallpaper_engine/assets"))
                    .help("Scenes reuse textures from Wallpaper Engine's own assets folder. Copy it from a Windows install to render them.")
                    .onSubmit { SceneSupport.invalidate(); WallpaperManager.shared.reload(force: true) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Edits a wallpaper's `general.properties`. Web wallpapers update live; scenes rebuild.
struct PropertiesView: View {
    let wallpaper: Wallpaper
    private let props: WallpaperProperties
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    init(wallpaper: Wallpaper) {
        self.wallpaper = wallpaper
        props = WallpaperProperties(json: wallpaper.project.propertiesJSON)
    }

    private var values: [String: Any] { props.values(settings.propertyOverrides[wallpaper.id] ?? [:]) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(wallpaper.title) {
                    ForEach(props.visible(values)) { row($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset to Defaults") { WallpaperManager.shared.resetProperties(wallpaper) }
                    .disabled(settings.propertyOverrides[wallpaper.id] == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func row(_ p: WallpaperProperty) -> some View {
        switch p.kind {
        case .color:
            ColorPicker(p.label, selection: Binding(
                get: { let c = WallpaperProperties.rgb(values[p.key]); return Color(.sRGB, red: c[0], green: c[1], blue: c[2]) },
                set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    set(p, WallpaperProperties.colorString([c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)))
                }), supportsOpacity: false)
        case .slider:
            let value = Binding(get: { (values[p.key] as? NSNumber)?.doubleValue ?? p.min },
                                set: { set(p, p.step >= 1 ? $0.rounded() : $0) })
            LabeledContent(p.label) {
                HStack {
                    Slider(value: value, in: p.min...max(p.max, p.min + p.step), step: p.step)
                    Text(value.wrappedValue, format: .number.precision(.fractionLength(p.step >= 1 ? 0 : 2)))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        case .bool:
            Toggle(p.label, isOn: Binding(get: { (values[p.key] as? NSNumber)?.boolValue ?? false }, set: { set(p, $0) }))
        case .combo:
            Picker(p.label, selection: Binding(
                get: { values[p.key].map { "\($0)" } ?? "" },
                set: { tag in if let o = p.options.first(where: { "\($0.value)" == tag }) { set(p, o.value) } })) {
                ForEach(p.options.indices, id: \.self) { i in Text(p.options[i].label).tag("\(p.options[i].value)") }
            }
        case .textinput:
            TextField(p.label, text: Binding(get: { values[p.key].map { "\($0)" } ?? "" }, set: { set(p, $0) }))
        case .text:
            Text(p.label).font(.callout).foregroundStyle(.secondary)
        case .other:
            EmptyView()
        }
    }

    private func set(_ p: WallpaperProperty, _ value: Any) {
        WallpaperManager.shared.setProperty(wallpaper, key: p.key, value: value)
    }
}
