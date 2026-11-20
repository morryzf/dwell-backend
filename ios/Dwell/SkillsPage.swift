import SwiftUI

/// Skills：她写给 Cloudy 的做法。平时他只看到名字和「什么时候用」，对得上的时候自己打开读正文。
struct Skill: Identifiable, Equatable {
    var id: String
    var name: String
    var whenText: String
    var body: String
    var enabled: Bool

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        whenText = json["when_text"] as? String ?? ""
        body = json["body"] as? String ?? ""
        enabled = json["enabled"] as? Bool ?? true
    }

    init() {
        id = ""
        name = ""
        whenText = ""
        body = ""
        enabled = true
    }

    var isNew: Bool { id.isEmpty }
}

struct SkillsPage: View {
    @State private var skills: [Skill] = []
    @State private var loaded = false
    @State private var editing: Skill?
    @State private var message = ""

    var body: some View {
        List {
            Section {
                SheetIntro(title: "Skills", subtitle: "写给 Cloudy 的做法：平时他只看到名字和「什么时候用」，对得上的时候自己打开读。")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section {
                if skills.isEmpty && loaded {
                    Text("还没有 skill。写第一份吧。").foregroundStyle(Theme.dim)
                }
                ForEach($skills) { $skill in
                    HStack(spacing: 12) {
                        Button { editing = skill } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name).foregroundStyle(skill.enabled ? Theme.text : Theme.dim)
                                if !skill.whenText.isEmpty {
                                    Text(skill.whenText).font(.system(size: 13)).foregroundStyle(Theme.dim).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle("", isOn: $skill.enabled)
                            .labelsHidden()
                            .onChange(of: skill.enabled) { _, on in
                                Task { await setEnabled(skill.id, on) }
                            }
                    }
                }
                Button { editing = Skill() } label: {
                    Label("新建", systemImage: "plus")
                }
            } footer: {
                if !message.isEmpty { Text(message) }
            }
        }
        .modifier(SheetListStyle())
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: Binding(get: { editing.map(EditingSkill.init) }, set: { editing = $0?.skill })) { item in
            SkillEditor(skill: item.skill) { Task { await load() } }
        }
    }

    private func load() async {
        if let json = try? await API.shared.request("GET", "api/skills") {
            skills = (json["items"] as? [[String: Any]] ?? []).map(Skill.init(json:))
        }
        loaded = true
    }

    private func setEnabled(_ id: String, _ on: Bool) async {
        do {
            _ = try await API.shared.request("PATCH", "api/skills/\(id)", body: ["enabled": on])
            message = ""
        } catch {
            message = "没改成：" + error.localizedDescription
            await load()
        }
    }
}

/// .sheet(item:) 要 Identifiable，而新建的那份 id 是空的：包一层，给它一个稳定的标识。
private struct EditingSkill: Identifiable {
    let skill: Skill
    var id: String { skill.isNew ? "new" : skill.id }
}

private struct SkillEditor: View {
    @State var skill: Skill
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var saving = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名字") {
                    TextField("比如：她难过的时候", text: $skill.name)
                }
                Section {
                    TextField("比如：Morry 难过、哭了、说自己不好的时候", text: $skill.whenText, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("什么时候用")
                } footer: {
                    Text("他每轮只看到这一句，写得越具体，他越容易在对的时候想起来。")
                }
                Section("正文") {
                    StableTextView(text: $skill.body, fontSize: 15, grows: true)
                        .frame(minHeight: 240)
                }
                if !skill.isNew {
                    Section {
                        Toggle("启用", isOn: $skill.enabled)
                        Button("删除这个 skill", role: .destructive) { confirmDelete = true }
                    }
                }
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(MemoryStyle.danger) }
                }
            }
            .navigationTitle(skill.isNew ? "新建 skill" : "编辑 skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { Task { await save() } }
                        .disabled(saving || skill.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("删除「\(skill.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await remove() } }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let body: [String: Any] = ["name": skill.name, "when_text": skill.whenText,
                                   "body": skill.body, "enabled": skill.enabled]
        do {
            if skill.isNew {
                _ = try await API.shared.request("POST", "api/skills", body: body)
            } else {
                _ = try await API.shared.request("PATCH", "api/skills/\(skill.id)", body: body)
            }
            onChange()
            dismiss()
        } catch {
            message = "没保存上：" + error.localizedDescription
        }
    }

    private func remove() async {
        do {
            _ = try await API.shared.request("DELETE", "api/skills/\(skill.id)")
            onChange()
            dismiss()
        } catch {
            message = "没删掉：" + error.localizedDescription
        }
    }
}
