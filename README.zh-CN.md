# CodexAccountBridge

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <img src="macos/CABDesktop/Resources/AppIcon.png" width="160" alt="CodexAccountBridge icon">
</p>

`codex-account-bridge`（命令名 `cab`）是在 macOS 和 Linux 上管理多个官方 Codex 登录的安全型开源工具，包含 CLI 与原生 macOS 管理界面。它可以管理本机和 SSH 远程服务器上的 Codex 账号、官方额度、会话与智能体绑定，同时不实现 OAuth、不代理模型流量、不复制令牌，也不会根据额度或错误自动切换账号。

## 为什么重新实现

现有多账号包装器证明了按 `CODEX_HOME` 隔离登录的可行性，但部分项目默认绕过 Codex 审批与沙箱、自动信任项目、自动复制上下文，甚至允许共享正在写入的 SQLite/WAL 文件。`cab` 改用保守默认值：

- 每个账号一个独立 `CODEX_HOME`，只通过官方 `codex login` 登录。
- 不读取或解析 `auth.json` 内容；状态检查只查看文件是否存在及权限。
- 不添加 `--dangerously-bypass-approvals-and-sandbox`。
- 不修改项目 trust 配置。
- 普通额度查询仅用于展示；可选的额度周期唤醒必须由用户主动开启，且不会因限额、认证失败或运行错误切换账号。
- 只有双重确认后才共享 `sessions/`，从不共享 `auth.json`、`config.toml` 或 SQLite/WAL。
- 配置原子写入、保留上一版 `.backup` 并强制 `0600`；所有配置更新由同一文件锁串行化，配置与账号目录拒绝符号链接并限制为 `0700`。
- 运行官方 Codex 时不经过 shell，参数保持原样。

详细审计见 [docs/UPSTREAM_AUDIT.md](docs/UPSTREAM_AUDIT.md)，威胁模型见 [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)。

## 安装

需要包含当前标准库安全修复的 Go 1.26.7+ 和已经安装的官方 Codex CLI：

```bash
git clone https://github.com/OrangeMagician/codex-account-bridge.git
cd codex-account-bridge
make check
make security-check
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

同时启动多个 `cab run` 或配置命令时，所有更新通过权限为 `0600` 的统一本地文件锁串行执行。轮换只选择登录身份，不共享历史会话；会话继承仍需单独执行上面的双重确认流程。

## 查看官方 Codex 额度

CAB 通过每个账号自己的 `CODEX_HOME` 启动官方 `codex app-server`，只读查询 ChatGPT 套餐和 Codex 额度周期：

```bash
# 查看所有账号
cab usage

# 查看指定账号
cab usage --account personal

# 供桌面端或脚本使用的稳定结构
cab usage --json
```

可用字段取决于官方账号接口实际返回值，包括套餐类型、主要/次要周期的已用百分比、额度重置时间、Credits、个人消费上限和可用额度重置次数。单个账号读取失败不会遮蔽其他账号的结果。

CAB 不直接读取 `auth.json`、钥匙串令牌或浏览器 Cookie；官方 Codex 进程使用它自己的登录状态完成查询。CAB 不会输出账号邮箱和官方返回的额度重置凭据 ID。普通额度查询仅用于展示；自动轮换不会根据剩余额度、接口错误或限额自动切号。官方接口不提供 ChatGPT 订阅续费或会员到期日，因此 CAB 只把 `resets_at` 标记为“额度重置时间”。

macOS 原生界面的“系统设置”提供可选的“额度重置通知”开关。开关默认关闭，仅在用户主动开启时申请系统通知权限；每次刷新额度后会替换 CAB 已安排的通知，关闭开关会撤销这些通知。通知只表示官方返回的重置时间已到，打开 CAB 刷新后可确认服务端最新额度。

自动额度刷新按账号独立判断：即使额度为 0，也会按设置间隔继续查询；手动刷新仍会查询全部账号。“系统设置”中的“额度周期唤醒”默认关闭。开启后，CAB 会在额度恢复或最多 3 个每天执行的周期启动时间先查询额度，仅当五小时或周周期没有倒计时时发送一次最低消耗的官方 Codex 请求。最多 3 个暂停自动刷新时段会抑制普通自动查询和额度恢复触发的请求，但显式设置的周期启动时间优先执行；请求后会再次核对官方重置时间，失败不会自动重试。

如需手动触发同样的最低消耗请求：

```bash
cab usage probe --account personal
```

该命令使用官方 Codex 的临时、只读工作区，不保存会话，也不输出模型响应。

## macOS 可视化界面

`CodexAccountBridge`（简体中文显示为“Codex账号管理”）是原生 SwiftUI 管理界面，可管理本机或 SSH 主机上的账号、官方登录、默认/Remote 账号、额度和轮换顺序。它会检测默认 `~/.codex` 是否已有官方登录，并允许用户为其填写本地名称后直接登记，不要求重复登录，也不读取 `auth.json` 内容。

```bash
make macos-app
open "dist/CodexAccountBridge.app"
```

可以保存多个远程服务器并在侧边栏切换管理。服务器显示名称和 SSH 主机只存入当前 Mac 的 UserDefaults，不进入项目配置；远程主机需要能在登录 PATH 中直接执行 `cab`。隐私边界见 [docs/PRIVACY.md](docs/PRIVACY.md)。

界面将操作分为两个层级：

- “管理概览”集中管理 Codex 桌面端账号、本机项目与会话保留、服务器跨账号会话共享和新任务自动轮换；这些策略作用于当前选择的整台 Mac 或 SSH 主机，不属于某个账号。
- 远程服务器的“智能体账号绑定”会发现 Hermes gateway/bridge 与 OpenClaw gateway 的 systemd 用户服务，并为每个服务明确选择一个已登录账号。CAB 只写自己管理的 `CODEX_HOME` drop-in，不读取或复制授权文件；运行中的服务会在确认后重启，失败时自动恢复原绑定。
- 单个账号页面只负责登录状态、重新认证、默认 CLI/Remote 账号和移除登记。已登录账号不会再把“登录”作为主操作。
- 账号列表显示剩余额度摘要；“管理概览”提供所有账号额度概览，账号详情显示完整周期、精确重置时间和官方可选 Credits/消费上限。额度按当前 Mac/远程服务器分别缓存在内存中，默认 15 分钟更新一次，也可在“系统设置”中选择 5/30/60 分钟或仅手动刷新；进入账号详情不会重复请求。
- 右上角“更多”菜单中的“系统设置”可管理语言、额度刷新、重置通知和额度周期唤醒，并可配置最多 3 个周期启动时间和 3 个暂停自动刷新时段。

“设为默认”只影响以后通过 `cab run` 或界面“在终端启动”的新 CLI 进程，不会热切换已经运行的 Codex 桌面客户端。本机需要在“管理概览 > Codex 桌面端”选择“用此账号启动”：应用会先明确提示关闭当前 Codex/ChatGPT 桌面端及其中的活动任务，然后用该账号独立的 `CODEX_HOME` 重新启动官方客户端。请先保存正在进行的工作；CAB 不会在后台静默切换。

“管理概览 > 项目与会话”中的“切换时保留”默认关闭。开启后，下一次桌面账号切换会在所有 Codex 进程停止后同步本地与远程项目、完整消息与会话目录、动态工具记录、长期目标、记忆、个人技能、规则、提示模板、附件、生成图片、侧栏状态、提示历史和未发送草稿，使多个登录身份共用同一套本地工作区体验。SSH 同步只复制官方 Codex 已保存的主机记录、远程路径和项目选择，不读取或复制私钥。写入前会逐项备份目标 JSON、目录和 SQLite；CAB 只合并经过列结构校验的白名单表，保留其他表和账号自己的处理水位，失败时自动回滚。账号身份、插件/OAuth、浏览器/Computer Use 配置、设备与远程控制授权、日志以及审批、沙箱和项目 trust 选择始终隔离，`auth.json` 和 `config.toml` 不共享、不读取、不复制。关闭该设置后，下一次切换会恢复每个账号独立的会话副本，项目列表也保持账号独立。

远程服务器修改会话共享时，界面会先列出仍在运行的 Codex PID、运行时长、终端和可执行文件。用户可以取消并自行保存任务，或明确选择“关闭这些进程并继续”；CAB 只向列表中的原 Codex 进程发送正常退出信号，不强制终止，且仅在全部退出后才修改会话共享。

如果服务器在使用 CAB 前已有 `~/.codex` 历史，远程会话卡片会显示待导入数量。用户明确确认后可将旧 `sessions/` 与 `archived_sessions/` 复制到共享库；源文件保留，CAB 不解析或输出会话正文，但导入后所有共享账号都能看到这些上下文。

需要迁移会话时，CAB 会在关闭桌面端之前预检其他 `codex` 进程，并区分官方桌面端子进程、VS Code/Cursor/JetBrains 扩展和普通 CLI。发现编辑器扩展或 CLI 仍在运行时会显示来源与 PID，保持桌面端不动；若预检后发生其他失败，则自动使用切换前的账号目录重新启动桌面端。进程识别只读取可执行文件路径，不读取命令参数或任务内容。

默认 `~/.codex` 账号与官方桌面客户端共用同一认证存储。对这个账号完成“重新登录”会由官方 Codex 替换原认证，因此只有确实要更换该身份时才应操作；界面会在开始前再次确认。其他 CAB 账号使用独立目录，正常桌面切换不需要重复登录。

服务器管理窗口支持“从 SSH 配置导入”：本地解析 `~/.ssh/config` 及其 `Include` 文件，只提取没有通配符的 `Host` 别名。`HostName`、`User`、`IdentityFile` 和私钥内容不会保存进应用；实际连接仍交给系统 `/usr/bin/ssh` 解析完整配置。

账号登录提供三种入口：

- 默认浏览器登录：执行官方 `codex login`，由 Codex 打开系统默认浏览器。
- 指定浏览器登录：使用普通 ChatGPT OAuth，在用户选择的 Safari、Chrome、Edge、Brave 或 Firefox 普通窗口打开，不改变系统默认浏览器。
- 无痕浏览器登录：通过官方 `codex app-server` 的 `account/login/start` 普通 ChatGPT OAuth 流程取得官方授权地址，再在用户选择的 Chrome、Edge、Brave 或 Firefox 无痕窗口打开；不需要启用设备代码授权。Codex app-server 自己负责 PKCE、本地回调、凭据保存和刷新，CAB 不接触令牌。远程服务器使用 SSH 本地端口转发完成同一官方回调。
- 设备码登录：执行官方 `codex login --device-auth`，仅作为远程或无浏览器环境的备用方式，需要用户在 ChatGPT 安全设置中启用设备代码授权。

无痕登录不会绕过官方认证，也不会让应用看到浏览器 Cookie、密码或最终令牌。设备登录的一次性代码只显示在当前操作输出中，不写入 CAB 配置。

## 手机 Remote → Mac → Ubuntu

官方支持手机连接 Mac/Windows 桌面版，再由桌面版通过 SSH 启动 Ubuntu 上的 Codex app-server。详细步骤见 [docs/REMOTE.md](docs/REMOTE.md)。Ubuntu 侧的核心步骤是：

```bash
cab remote use work
cab shim install --dir ~/.local/bin --force
command -v codex
codex --version
```

shim 会让桌面版执行的 `codex app-server` 使用 `cab remote use` 固定的账号。切换账号后，应先结束现有远程任务，再运行 `cab remote use NAME` 并重新连接 SSH 主机。不要在同一个进行中的远程任务中途换账号。

也可以在服务器终端显式管理支持的智能体服务：

```bash
cab agent list
cab agent bind --service hermes-gateway-coder.service --account work --confirm-restart-agent
cab agent bind-all --account work --confirm-restart-agent
cab agent unbind --service hermes-gateway-coder.service --confirm-restart-agent
```

CAB 不会因额度、限流、认证或运行错误自动切换智能体账号。服务未运行时只保存绑定而不会启动；服务运行时必须显式确认重启，以免静默中断任务。

移除 shim 会恢复最近一次安装时创建的备份：

```bash
cab shim remove --dir ~/.local/bin
```

Mac 与 Ubuntu 之间的同一会话优先使用官方 Handoff，不直接同步 Codex SQLite 数据库。

## 诊断

```bash
cab doctor

# 仅当 doctor 报告上次会话迁移被中断时
cab doctor --repair
```

诊断只检查可执行文件、目录、符号链接、事务日志和权限，不读取令牌内容。会话共享启用/关闭使用可恢复事务日志；普通命令会自动恢复安全的中断操作，也可显式运行 `cab doctor --repair`。

## 配置位置

- 配置：`${XDG_CONFIG_HOME:-~/.config}/codex-account-bridge/config.json`
- 数据：`${XDG_DATA_HOME:-~/.local/share}/codex-account-bridge/`
- 测试或便携运行可使用 `CAB_CONFIG_HOME`、`CAB_DATA_HOME`。
- 官方 Codex 路径探测异常时可显式设置 `CAB_REAL_CODEX=/absolute/path/to/codex`。该变量必须是绝对路径；自动 PATH 探测忽略相对目录、当前项目内的候选文件及组/其他用户可写的可执行文件。

## 不提供的功能

- 按限额/错误自动切号，或失败后换号重试。
- 第三方 OpenAI-compatible 代理配置。
- OAuth 实现、令牌导入导出、网页令牌面板。
- 多机器实时同步内部状态数据库。
- 对 OpenAI 服务条款、账号资格或功能可用性的保证。

## 开发

```bash
make check
make security-check
make release VERSION=0.1.0
make macos-app VERSION=0.1.0 BUILD_NUMBER=1
```

项目不使用 GitHub Actions。发布构建由维护者在本地生成并核对 SHA-256。

## License

Apache License 2.0。Codex 和 ChatGPT 是其各自权利人的产品与商标，本项目未获得 OpenAI 官方背书。
