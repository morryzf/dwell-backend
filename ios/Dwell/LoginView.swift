import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var store: ChatStore

    @State private var server = API.shared.baseURL?.absoluteString ?? ""
    @State private var user = ""
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://dwell.example.com", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("服务器")
                } footer: {
                    Text("就是你平时在浏览器里打开 Dwell 的那个地址。")
                }

                Section("账号") {
                    TextField("用户名", text: $user)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("进门") }
                            Spacer()
                        }
                    }
                    .disabled(busy || server.isEmpty || user.isEmpty || password.isEmpty)
                } footer: {
                    if !error.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Dwell")
        }
    }

    private func submit() async {
        busy = true
        error = ""
        defer { busy = false }
        do {
            try await store.login(server: server, user: user, password: password)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
