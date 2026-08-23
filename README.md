# codex-account-bridge

`codex-account-bridge`（命令名 `cab`）是在 macOS 和 Linux 上管理多个官方 Codex 登录的安全型开源 CLI。它不实现 OAuth、不代理模型流量、不复制令牌，也不会自动轮换账号规避额度限制。

> 当前状态：早期预览。请先在非关键账号和仓库中验证，再用于日常工作。

## 为什么重新实现

现有多账号包装器证明了按 `CODEX_HOME` 隔离登录的可行性，但部分项目默认绕过 Codex 审批与沙箱、自动信任项目、自动复制上下文，甚至允许共享正在写入的 SQLite/WAL 文件。`cab` 改用保守默认值：

- 每个账号一个独立 `CODEX_HOME`，只通过官方 `codex login` 登录。
- 不读取或解析 `auth.json` 内容；状态检查只查看文件是否存在及权限。
- 不添加 `--dangerously-bypass-approvals-and-sandbox`。
- 不修改项目 trust 配置。
- 不探测额度、不自动换号。
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

- 自动探测额度或自动轮换账号。
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
