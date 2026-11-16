import AppKit
import SwiftUI

private struct LocalAPIStatus: Decodable {
    var enabled = false
    var running = false
    var account = ""
    var listen = "127.0.0.1:8787"
    var client = "127.0.0.1"
    var model = "MODEL@EFFORT@SPEED"
}

struct LocalAPISettingsView: View {
    var performsLiveChecks: Bool
    @EnvironmentObject private var store: CABStore
    @State private var status = LocalAPIStatus()
    @AppStorage("localAPI.listen") private var listen = "127.0.0.1:8787"
    @AppStorage("localAPI.client") private var client = "127.0.0.1"
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    private let service = CABService()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(status.running ? "运行中" : (status.enabled ? "服务未就绪" : "未启动"),
                          systemImage: "network")
                    Spacer()
                    Button(status.enabled ? "停止服务" : "启动服务") {
                        perform(status.enabled ? ["stop"] : ["start", "--listen", listen, "--client", client])
                    }
                    .disabled(!status.enabled && status.account.isEmpty)
                }
                Divider()
                Picker("服务账号", selection: Binding(get: { status.account }, set: { name in
                    if !name.isEmpty { perform(["use", name]) }
                })) {
                    Text("选择账号").tag("")
                    ForEach(store.status.accounts) { account in
                        Text(account.name).tag(account.name)
                    }
                }
                Text("切换后，新请求及客户端附带的对话历史将使用所选账号。")
                    .font(.caption).foregroundStyle(.secondary)
                if status.enabled {
                    LabeledContent("请求地址") { Text(verbatim: "http://\(status.listen)/v1").textSelection(.enabled) }
                    LabeledContent("允许的客户端 IP") { Text(verbatim: status.client) }
                } else {
                    LabeledContent("监听地址") {
                        TextField("IP:port", text: $listen).textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("允许的客户端 IP") {
                        TextField("IP", text: $client).textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    Text("模型 ID")
                    Text(verbatim: status.model).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(copied ? "已复制" : "复制 API 密钥") { perform(["key"]) }
                        .disabled(status.account.isEmpty)
                }
                Text("同花顺可填写实际模型 ID，或使用 模型@推理强度。追加 @fast 开启快速档位。省略推理强度时用 medium，省略速度时用普通速度。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .padding(8)
            .disabled(busy)
        } label: { Text("本地模型接口") }
        .task { if performsLiveChecks { await refresh() } }
    }

    private func execute(_ args: [String]) async throws -> String {
        let result = try await service.execute(["api"] + args, target: .local, remoteHost: "")
        guard result.exitCode == 0 else { throw BridgeError.commandFailed(result.errorOutput) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor private func refresh() async {
        do {
            let output = try await execute(["status"])
            status = try JSONDecoder().decode(LocalAPIStatus.self, from: Data(output.utf8))
            if status.enabled {
                listen = status.listen
                client = status.client
            }
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ args: [String]) {
        busy = true
        copied = false
        error = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let output = try await execute(args)
                if args == ["key"] {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(output, forType: .string)
                } else { await refresh() }
            } catch { self.error = error.localizedDescription }
        }
    }
}
