# codex-account-bridge

`codex-account-bridge`（命令名 `cab`）是在 macOS 和 Linux 上管理多个官方 Codex 登录的安全型开源工具，包含 CLI 与原生 macOS 管理界面。它不实现 OAuth、不代理模型流量、不复制令牌，也不会根据额度或错误自动切换账号。

> 当前状态：早期预览。请先在非关键账号和仓库中验证，再用于日常工作。

## 为什么重新实现

现有多账号包装器证明了按 `CODEX_HOME` 隔离登录的可行性，但部分项目默认绕过 Codex 审批与沙箱、自动信任项目、自动复制上下文，甚至允许共享正在写入的 SQLite/WAL 文件。`cab` 改用保守默认值：

- 每个账号一个独立 `CODEX_HOME`，只通过官方 `codex login` 登录。
- 不读取或解析 `auth.json` 内容；状态检查只查看文件是否存在及权限。
- 不添加 `--dangerously-bypass-approvals-and-sandbox`。
- 不修改项目 trust 配置。
- 不探测额度，不因限额、认证失败或运行错误切换账号；用户可以明确配置“每次新启动轮换”。
- 只有双重确认后才共享 `sessions/`，从不共享 `auth.json`、`config.toml` 或 SQLite/WAL。
- 配置原子写入、保留上一版 `.backup` 并强制 `0600`；配置与账号目录拒绝符号链接并限制为 `0700`。
- 运行官方 Codex 时不经过 shell，参数保持原样。

详细审计见 [docs/UPSTREAM_AUDIT.md](docs/UPSTREAM_AUDIT.md)，威胁模型见 [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)。

## 安装

需要 Go 1.20+ 和已经安装的官方 Codex CLI：

```bash
git clone https://github.com/OrangeMagician/codex-account-bridge.git
cd codex-account-bridge
make check
make build
install -m 0755 bin/cab ~/.local/bin/cab
```

确认 `~/.local/bin` 位于 `PATH` 中，然后运行：

```bash
cab init
cab version
```

## 多账号真实登录

```bash
cab account add personal
cab account add work

# Mac 有浏览器时
cab login personal

# Ubuntu/headless 主机
cab login --device-auth work

cab account list
cab use personal
cab run
cab run --account work -- exec "explain this repository"
```

`cab run` 后面的参数直接传递给官方 `codex`。`cab account remove` 只移除登记，不删除账号目录、登录或会话。

如果默认 `~/.codex` 已经通过官方 Codex 登录，不需要重复登录，可以直接登记：

```bash
cab account import-current current
```

该命令先调用官方 `codex login status` 确认登录状态，再登记原目录；不会读取或复制凭据。CAB Desktop 会自动显示同等功能的“登记现有登录”入口。

## 跨账号继承本机会话

这会让账号 B 在恢复会话时看到账号 A 的历史上下文，必须先停止涉及这些账号的全部 Codex 进程，并明确确认：

```bash
cab sessions enable \
  --acknowledge-cross-account-context \
  --confirm-codex-stopped

cab run --account work -- resume --last
```

关闭共享并为每个账号复制一份当前会话：

```bash
cab sessions disable --confirm-codex-stopped
```

迁移遇到同路径但内容不同的会话会立即停止，不覆盖任何一方。启用共享时原目录会保留为带时间戳的 `.cab-backup-*`，用于人工恢复。

## 用户配置的新启动轮换

轮换默认关闭。它只在没有显式传入 `--account` 的 `cab run` 启动前，按用户保存的顺序选择下一个账号；不会读取额度，也不会在限额、认证失败或其他错误后自动重试或切换正在运行的任务：

```bash
cab rotation configure --accounts personal,work
cab rotation enable
cab rotation status

# 每次新执行依次使用 personal、work、personal……
cab run

# 显式账号始终优先，且不会推进轮换位置
cab run --account work

cab rotation disable
```

同时启动多个 `cab run` 时，轮换位置通过权限为 `0600` 的本地文件锁串行更新。轮换只选择登录身份，不共享历史会话；会话继承仍需单独执行上面的双重确认流程。

## macOS 可视化界面

`CodexAccountBridge`（简体中文显示为“Codex账号管理”）是原生 SwiftUI 管理界面，可管理本机或 SSH 主机上的账号、官方登录、默认/Remote 账号和轮换顺序。它会检测默认 `~/.codex` 是否已有官方登录，并允许用户为其填写本地名称后直接登记，不要求重复登录，也不读取 `auth.json` 内容。

```bash
make macos-app
open "dist/CodexAccountBridge.app"
```

可以保存多个远程服务器并在侧边栏切换管理。服务器显示名称和 SSH 主机只存入当前 Mac 的 UserDefaults，不进入项目配置；远程主机需要能在登录 PATH 中直接执行 `cab`。隐私边界见 [docs/PRIVACY.md](docs/PRIVACY.md)。

服务器管理窗口支持“从 SSH 配置导入”：本地解析 `~/.ssh/config` 及其 `Include` 文件，只提取没有通配符的 `Host` 别名。`HostName`、`User`、`IdentityFile` 和私钥内容不会保存进应用；实际连接仍交给系统 `/usr/bin/ssh` 解析完整配置。

账号登录提供三种入口：

- 默认浏览器登录：执行官方 `codex login`，由 Codex 打开系统默认浏览器。
- 设备码登录：执行官方 `codex login --device-auth`，显示短期有效的网址和一次性代码，并由桌面端在 Mac 的默认浏览器打开官方页面；也可在任意设备或任意浏览器中手动打开网址、输入代码并选择账号。
- 无痕登录：使用同一官方设备码流程，检测输出中的 OpenAI/ChatGPT 官方 HTTPS 地址，并让用户选择 Chrome、Edge、Brave 或 Firefox 的无痕窗口打开。Safari 可手动使用“设备码登录”并在私人浏览窗口输入网址。

无痕登录不会绕过官方认证，也不会让应用看到浏览器 Cookie、密码或最终令牌。一次性代码只显示在当前操作输出中，不写入 CAB 配置。

## 手机 Remote → Mac → Ubuntu

官方支持手机连接 Mac/Windows 桌面版，再由桌面版通过 SSH 启动 Ubuntu 上的 Codex app-server。详细步骤见 [docs/REMOTE.md](docs/REMOTE.md)。Ubuntu 侧的核心步骤是：

```bash
cab remote use work
cab shim install --dir ~/.local/bin --force
command -v codex
codex --version
```

shim 会让桌面版执行的 `codex app-server` 使用 `cab remote use` 固定的账号。切换账号后，应先结束现有远程任务，再运行 `cab remote use NAME` 并重新连接 SSH 主机。不要在同一个进行中的远程任务中途换账号。

移除 shim 会恢复最近一次安装时创建的备份：

```bash
cab shim remove --dir ~/.local/bin
```

Mac 与 Ubuntu 之间的同一会话优先使用官方 Handoff，不直接同步 Codex SQLite 数据库。

## 诊断

```bash
cab doctor
```

诊断只检查可执行文件、目录、符号链接和权限，不读取令牌内容。

## 配置位置

- 配置：`${XDG_CONFIG_HOME:-~/.config}/codex-account-bridge/config.json`
- 数据：`${XDG_DATA_HOME:-~/.local/share}/codex-account-bridge/`
- 测试或便携运行可使用 `CAB_CONFIG_HOME`、`CAB_DATA_HOME`。
- 官方 Codex 路径探测异常时可显式设置 `CAB_REAL_CODEX=/absolute/path/to/codex`。

## 不提供的功能

- 自动探测额度、按限额/错误切号或失败后换号重试。
- 第三方 OpenAI-compatible 代理配置。
- OAuth 实现、令牌导入导出、网页令牌面板。
- 多机器实时同步内部状态数据库。
- 对 OpenAI 服务条款、账号资格或功能可用性的保证。

## 开发

```bash
make check
make release VERSION=0.1.0
```

项目不使用 GitHub Actions。发布构建由维护者在本地生成并核对 SHA-256。

## License

Apache License 2.0。Codex 和 ChatGPT 是其各自权利人的产品与商标，本项目未获得 OpenAI 官方背书。
