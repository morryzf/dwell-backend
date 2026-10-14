import PhotosUI
import SwiftUI

/// 「聊天背景」：照网页的 #backgroundSheet，再多一种会动的光晕。两位助手各用各的背景，只留在这台手机上。
struct BackgroundSettings: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.colorScheme) private var scheme

    @State private var who = "cloudy"
    /// 这页上选中的种类：选了「图片」但还没挑图时，先不存，等挑好了再算数。
    @State private var kind = "paper"
    @State private var mode = "light"
    @State private var picked: PhotosPickerItem?
    @State private var message = ""
    @State private var picking: [String: (color: Color, hex: String)] = [:]

    private var whoName: String {
        store.assistant?.all.first { $0.id == who }?.name ?? (who == "chatgpt" ? "ChatGPT" : "Cloudy")
    }

    private var glow: Binding<Glow> {
        Binding(get: { appearance.glow(who) }, set: { appearance.setGlow($0, for: who) })
    }

    var body: some View {
        List {
            Section {
                SheetIntro(title: "聊天背景", subtitle: "两位助手各用各的背景：方格纸、自己的图，或者会慢慢飘的光晕。只留在这台手机上。")
                Picker("助手", selection: $who) {
                    ForEach(store.assistant?.all ?? []) { item in Text(item.name).tag(item.id) }
                }
                .pickerStyle(.segmented)
                Picker("背景", selection: $kind) {
                    Text("方格纸").tag("paper")
                    Text("图片").tag("image")
                    Text("光晕").tag("glow")
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 6)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            switch kind {
            case "image": imageSections
            case "glow": glowSections
            default:
                Section {} footer: { Text("默认的粉灰格纹，跟网页一样。") }
            }
        }
        .modifier(SheetListStyle())
        .safeAreaInset(edge: .top, spacing: 0) { preview }
        .navigationTitle("聊天背景")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            who = store.assistant?.id ?? "cloudy"
            kind = appearance.backgroundKind(who)
            mode = scheme == .dark ? "dark" : "light"
        }
        .onChange(of: who) { _, value in kind = appearance.backgroundKind(value) }
        .onChange(of: kind) { _, value in
            guard value != appearance.backgroundKind(who) else { return }
            if value != "image" || appearance.background(who) != nil {
                appearance.setBackgroundKind(value, for: who)
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                message = "正在处理图片…"
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    appearance.setBackground(image, for: who)
                    message = ""
                } else {
                    message = "这张图片打不开"
                }
                picked = nil
            }
        }
    }

    /// 钉在顶上的预览，往下翻着调也看得见；调光晕时按正在调的那一套（浅色或深色）画。
    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            ChatBackground(assistant: who)
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.chip))
                .padding(12)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .allowsHitTesting(false)
        .environment(\.colorScheme, kind == "glow" ? (mode == "dark" ? .dark : .light) : scheme)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var caption: String {
        switch appearance.backgroundKind(who) {
        case "glow": return "\(whoName) 用的是光晕背景"
        case "image": return "\(whoName) 正在使用这张背景图"
        default: return kind == "image" ? "挑一张图，\(whoName) 就换上它" : "\(whoName) 用的是默认的粉灰格纹背景"
        }
    }

    @ViewBuilder private var imageSections: some View {
        if appearance.background(who) != nil {
            Section {
                HStack {
                    Text("背景遮罩")
                    Spacer()
                    Text("\(Int(appearance.overlay(who)))%").foregroundStyle(Theme.dim)
                }
                Slider(value: Binding(get: { appearance.overlay(who) },
                                      set: { appearance.setOverlay($0, for: who) }),
                       in: 0...100, step: 1)
                    .tint(Theme.send)
            } footer: {
                Text("数值越高，背景图越柔和、文字越清楚；设为 0% 可看原图。")
            }
        }

        Section {
            PhotosPicker(selection: $picked, matching: .images) {
                Label(appearance.background(who) == nil ? "从相册选择图片" : "换一张图片", systemImage: "photo")
            }
            if appearance.background(who) != nil {
                Button("删掉这张图", role: .destructive) {
                    appearance.setBackground(nil, for: who)
                    kind = "paper"
                }
            }
        } footer: {
            Text(message.isEmpty ? "图片会在手机上压缩后保存；不会上传到服务器，也不会发送给任何一位助手。" : message)
        }
    }

    @ViewBuilder private var glowSections: some View {
        Section("配色") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(GlowPreset.all) { preset in presetButton(preset) }
                }
                .padding(.vertical, 4)
            }
        }

        Section {
            Picker("模式", selection: $mode) {
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            .pickerStyle(.segmented)
            ColorPicker("底色", selection: colorBinding(-1), supportsOpacity: false)
            ForEach(0..<3, id: \.self) { index in
                ColorPicker("光晕 \(["一", "二", "三"][index])", selection: colorBinding(index), supportsOpacity: false)
            }
        } header: {
            Text("颜色")
        } footer: {
            Text("浅色、深色各一套，跟着手机的模式自动换。现在调的是\(mode == "dark" ? "深色" : "浅色")那套。")
        }

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("飘动")
                Picker("飘动", selection: glow.speed) {
                    Text("静止").tag(0)
                    Text("慢").tag(1)
                    Text("中").tag(2)
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("浓淡")
                    Spacer()
                    Text("\(Int(glow.wrappedValue.intensity))%").foregroundStyle(Theme.dim).monospacedDigit()
                }
                Slider(value: glow.intensity, in: 10...100, step: 1).tint(Theme.send)
            }
        } footer: {
            Text("手机开了「减弱动态效果」时光晕不动；app 在后台、或者上面盖着整页时也停着，不费电。")
        }

        Section {
            Button("恢复默认配色", role: .destructive) {
                picking = [:]
                appearance.resetGlow(for: who)
            }
        }
    }

    private func presetButton(_ preset: GlowPreset) -> some View {
        let palette = mode == "dark" ? preset.dark : preset.light
        let current = glow.wrappedValue
        let selected = current.light == preset.light && current.dark == preset.dark
        return Button {
            picking = [:]
            var value = glow.wrappedValue
            value.light = preset.light
            value.dark = preset.dark
            glow.wrappedValue = value
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(hexString: palette.base))
                    Circle().fill(AngularGradient(colors: (palette.colors + [palette.colors[0]]).map { Color(hexString: $0) },
                                                  center: .center))
                        .blur(radius: 5)
                        .opacity(0.9)
                        .clipShape(Circle())
                }
                .frame(width: 46, height: 46)
                .overlay(Circle().stroke(selected ? Theme.send : Theme.dim.opacity(0.25), lineWidth: selected ? 2.5 : 1))
                Text(preset.name)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Theme.text : Theme.dim)
            }
        }
        .buttonStyle(.plain)
    }

    /// 取色器拖动时把它给的颜色原样还给它，只往存储里写 #rrggbb（跟玻璃效果那里一样，免得滑块互相牵着跑）。
    /// index -1 是底色，0–2 是三个光晕。
    private func colorBinding(_ index: Int) -> Binding<Color> {
        let slot = "\(who)-\(mode)-\(index)"
        func stored() -> String {
            let palette = glow.wrappedValue.palette(mode)
            return index < 0 ? palette.base : (palette.colors.indices.contains(index) ? palette.colors[index] : "#ffffff")
        }
        return Binding(get: {
            let hex = stored()
            if let live = picking[slot], live.hex == hex { return live.color }
            return Color(hexString: hex)
        }, set: { color in
            let hex = color.hexString
            picking[slot] = (color, hex)
            var value = glow.wrappedValue
            var palette = value.palette(mode)
            if index < 0 {
                palette.base = hex
            } else {
                while palette.colors.count <= index { palette.colors.append("#ffffff") }
                palette.colors[index] = hex
            }
            if mode == "dark" { value.dark = palette } else { value.light = palette }
            glow.wrappedValue = value
        })
    }
}

/// 「玻璃效果」：照网页的 #messageStyleSheet。我的消息、Cloudy、ChatGPT 各一套，浅色深色各一套。
struct GlassSettings: View {
    @EnvironmentObject private var store: ChatStore
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.colorScheme) private var scheme

    @State private var role = "me"
    @State private var mode = "light"
    @State private var picking: [String: (color: Color, hex: String)] = [:]
    @State private var surface: GlassSurface = .composer

    private var liquidAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 模糊只给五档（关 / 很轻 / 轻 / 中 / 重），系统毛玻璃就这么几层厚度。
    private func blurPicker(_ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模糊")
            Picker("模糊", selection: Binding(get: { BlurLevel.of(value.wrappedValue) },
                                             set: { value.wrappedValue = $0.px })) {
                ForEach(BlurLevel.allCases) { level in Text(level.label).tag(level) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func glassBinding(_ key: WritableKeyPath<GlassValue, Double>) -> Binding<Double> {
        Binding(get: { appearance.glass(surface, mode)[keyPath: key] },
                set: { value in
                    var glass = appearance.glass(surface, mode)
                    glass[keyPath: key] = value
                    appearance.setGlass(glass, surface, mode)
                })
    }

    private var style: Binding<MessageStyle> {
        Binding(get: { appearance.style(role, mode) },
                set: { appearance.setStyle($0, role: role, mode: mode) })
    }

    var body: some View {
        List {
            Section {
                SheetIntro(title: "玻璃效果", subtitle: "调消息气泡的颜色、透明度、边框和圆角，还有输入框、侧边栏、整页弹窗有多透。只存在这台手机上。")
                Picker("谁的消息", selection: $role) {
                    Text("Me").tag("me")
                    Text("Cloudy").tag("cloudy")
                    Text("GPT").tag("chatgpt")
                }
                .pickerStyle(.segmented)
                Picker("模式", selection: $mode) {
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 6)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                Toggle("Liquid Glass", isOn: $appearance.liquidGlass)
                    .tint(Theme.send)
                    .disabled(!liquidAvailable)
            } footer: {
                Text(liquidAvailable
                     ? "用 iOS 26 系统的液态玻璃：气泡、输入框、按钮、侧边栏和弹窗都会跟着光线流动。关掉就回到磨砂玻璃。下面的颜色、不透明度和模糊档位两种都管用。"
                     : "液态玻璃要 iOS 26 才有，这台手机上用的是磨砂玻璃。")
            }

            Section("气泡") {
                ColorPicker("底色", selection: colorBinding(\.background), supportsOpacity: false)
                slider("底色不透明度", value: style.backgroundOpacity, range: 0...100, unit: "%")
                blurPicker(style.blur)
                slider("圆角", value: style.radius, range: 4...32, unit: "")
            }
            Section("边框") {
                ColorPicker("边框颜色", selection: colorBinding(\.border), supportsOpacity: false)
                slider("边框不透明度", value: style.borderOpacity, range: 0...100, unit: "%")
                slider("边框粗细", value: style.borderWidth, range: 0...3, unit: "", step: 0.5)
            }
            Section("文字") {
                ColorPicker("文字颜色", selection: colorBinding(\.text), supportsOpacity: false)
            }
            Section {
                Button("恢复这一套气泡的默认值") { appearance.resetStyle(role: role, mode: mode) }
            }

            // 网页「玻璃效果」下半截：输入框、侧边栏、整页弹窗的透明度和模糊。
            Section {
                Picker("调哪里", selection: $surface) {
                    ForEach(GlassSurface.allCases) { item in Text(item.label).tag(item) }
                }
                .pickerStyle(.segmented)
                slider("不透明度", value: glassBinding(\.opacity), range: 0...100, unit: "%")
                blurPicker(glassBinding(\.blur))
                Button("恢复\(surface.label)的默认值") { appearance.resetGlass(surface, mode) }
            } header: {
                Text("界面")
            } footer: {
                Text("跟上面的「浅色 / 深色」走：现在调的是\(mode == "dark" ? "深色" : "浅色")模式下的\(surface.label)。")
            }
        }
        .modifier(SheetListStyle())
        .safeAreaInset(edge: .top, spacing: 0) { preview }
        .navigationTitle("玻璃效果")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mode = scheme == .dark ? "dark" : "light" }
    }

    /// 预览按正在编辑的那一套画，不管现在手机是浅色还是深色。
    /// 预览：用聊天页同一个背景、同一种气泡和输入框，按正在编辑的那一套（浅色或深色）画；
    /// 钉在页面顶上，往下翻着调也一直看得见。
    private var preview: some View {
        let who = role == "chatgpt" ? "chatgpt" : (role == "cloudy" ? "cloudy" : (store.assistant?.id ?? "cloudy"))
        return ZStack(alignment: .bottom) {
            ChatBackground(assistant: who)
            VStack(spacing: 10) {
                Bubble(text: "卤肉饭，好。妈妈做的手艺。吃饱了吗？")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Bubble(text: "妈妈做的卤肉饭", isMe: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                HStack {
                    Text("说点什么…").font(.system(size: 14)).foregroundStyle(Theme.dim)
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .buttonGlass(Circle(), tint: Theme.send, fallback: Theme.send)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(GlassBackground(surface: .composer, shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
            }
            .environment(\.bubbleMaxWidth, 230)
            .environment(\.assistantID, who)
            .padding(14)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 预览只给人看：背景图铺满时会超出这块框，不关掉它接手指，就会把下面的按钮挡住。
        .allowsHitTesting(false)
        .environment(\.colorScheme, mode == "dark" ? .dark : .light)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// 取色器拖动时把它给的颜色原样还给它（只往存储里写 #rrggbb），
    /// 不然每动一下都要绕一圈「颜色 → 六位码 → 颜色」，三根滑块会互相牵着跑。
    private func colorBinding(_ key: WritableKeyPath<MessageStyle, String>) -> Binding<Color> {
        let slot = "\(role)-\(mode)-\(key.hashValue)"
        return Binding(get: {
            let stored = style.wrappedValue[keyPath: key]
            if let live = picking[slot], live.hex == stored { return live.color }
            return Color(hexString: stored)
        }, set: { color in
            let hex = color.hexString
            picking[slot] = (color, hex)
            style.wrappedValue[keyPath: key] = hex
        })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        unit: String, step: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(step < 1 ? String(format: "%.1f", value.wrappedValue) : "\(Int(value.wrappedValue))\(unit)")
                    .foregroundStyle(Theme.dim)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step).tint(Theme.send)
        }
    }
}
