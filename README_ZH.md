# Codex Remote Connector

[English README](README.md)

Codex Remote Connector 用来把一台 SSH 远程机器准备成 Codex desktop app 可以连接的远程开发环境。它会校验本地 SSH alias，在远程机器安装 Codex CLI，启动反向代理隧道，在远程机器执行 Codex device login，并输出 Codex desktop **Settings > Connections > SSH** 里需要填写的连接字段。

## 功能概览

当你对某个 SSH alias 运行 Remote Connector 时，它会：

1. 读取 `~/.ssh/config`，确认该 alias 是一个明确的 `Host` 条目。
2. 检查远程机器是否已经有 `~/.codex/bin/codex`。
3. 只有远程 Codex CLI 缺失时，才安装或修复远程 Codex。
4. 检查本地是否已经有匹配的反向 SSH 隧道进程。
5. 只有端口映射缺失时，才从远程机器到本地代理启动或修复反向 SSH 隧道：

   ```bash
   ssh -fN -R 127.0.0.1:17890:127.0.0.1:7890 REMOTE_SSH_MACHINE
   ```

6. 检查远程 Codex 是否已有认证文件。
7. 只有认证缺失时，才在远程机器执行 `codex login --device-auth`。
8. 输出 Codex desktop **Settings > Connections > SSH** 里连接远程机器所需的配置字段。

内置安装脚本会把远程 Codex binary 安装到 `~/.codex/bin/codex`。远程 Codex 运行时会通过 `http://127.0.0.1:17890` 访问本地代理。

同一台机器可以安全地重复运行同一条命令。再次调用会作为健康检查和自动修复流程：已经完善的远程安装、端口映射和登录状态会被跳过，缺失的部分会自动补齐。

## 环境要求

本地机器：

- Codex desktop app。
- 可用的 OpenSSH 客户端，包括 `ssh` 和 `scp`。
- `~/.ssh/config` 中有一个明确的 SSH `Host` alias。
- 推荐有一个监听在 `127.0.0.1:7890` 的本地 HTTP 代理；如果端口不同，可以传入 `REMOTE_FORWAR_PORT` 或使用 `--local-proxy`。

远程机器：

- macOS 或 Linux。
- x64 或 ARM64 CPU。
- `sh`、`tar`、`mktemp`，以及 `curl` 或 `wget`。
- 能访问 GitHub releases 下载 Codex；如果不能访问，可以跳过安装并自行提供 Codex。
- SSH 用户应当就是后续运行 Codex 的用户。

## 在 Codex 中安装插件

最简单的方式是直接让 Codex 帮你安装。在一个 Codex thread 中粘贴下面任意一段指令。

中文：

```text
请帮我从 https://github.com/wanghao9610/Codex-Remote-Connector 安装 Codex 插件。请把插件 clone 到 ~/plugins/remote-connector，配置 personal marketplace，运行 codex plugin add remote-connector@personal，并告诉我安装完成后如何使用 @Remote-Connector。
```

English:

```text
Please install the Codex plugin from https://github.com/wanghao9610/Codex-Remote-Connector. Clone it to ~/plugins/remote-connector, configure the personal marketplace, run codex plugin add remote-connector@personal, and tell me how to use @Remote-Connector after installation.
```

Codex 可能会在写入当前 workspace 外部路径前请求授权，例如创建 `~/plugins/remote-connector` 或编辑 `~/.agents/plugins/marketplace.json`。如果路径正确，请批准这些操作。

Codex 会处理 clone、personal marketplace 配置和插件安装命令。插件安装完成只表示 `@Remote-Connector` 可用，还需要为每台远程机器完成远程准备流程，并在 Codex desktop 里添加对应的 SSH connection。

安装完成后，开启一个新的 Codex thread，然后调用：

```text
@Remote-Connector devbox
```

当远程安装、反向隧道和 device login 完成后，打开 **Codex > Settings > Connections > SSH**，用脚本输出的字段手动添加或启用对应的远程服务器。你也可以让 Codex 根据脚本输出尝试自动添加；如果当前环境无法自动操作 Codex desktop UI，就按输出字段手动填写。

## 手动安装

只有在你想自己安装，或需要调试安装路径时，才需要看这一节。

Codex 会通过本地 marketplace 发现插件，然后把插件安装到自己的 cache 目录。默认 personal marketplace 下有三类路径需要区分：

- Marketplace 配置：`~/.agents/plugins/marketplace.json`
- 插件源码 checkout：`~/plugins/remote-connector`
- Codex 安装后的 cache：`~/.codex/plugins/cache/personal/remote-connector/<version>/`

不要把插件 clone 到 `~/.agents/plugins/plugins/remote-connector` 或 `~/.codex/plugins/cache/...`。`~/.agents` 下放 marketplace 配置，`~/plugins` 下放源码 checkout，`~/.codex/plugins/cache` 下的内容由 `codex plugin add` 自动生成。

1. 从 GitHub clone 插件源码。

   ```bash
   mkdir -p ~/plugins
   git clone https://github.com/wanghao9610/Codex-Remote-Connector.git ~/plugins/remote-connector
   ```

   如果已经 clone 过，更新源码：

   ```bash
   cd ~/plugins/remote-connector
   git pull
   ```

   如果你正在使用本地开发 checkout，也可以用 symlink：

   ```bash
   mkdir -p ~/plugins
   ln -s /path/to/Codex-Remote-Connector ~/plugins/remote-connector
   ```

2. 添加 personal marketplace 条目。

   默认 personal marketplace 文件是：

   ```text
   ~/.agents/plugins/marketplace.json
   ```

   如果文件不存在，可以创建为：

   ```json
   {
     "name": "personal",
     "interface": {
       "displayName": "Personal"
     },
     "plugins": [
       {
         "name": "remote-connector",
         "source": {
           "source": "local",
           "path": "./plugins/remote-connector"
         },
         "policy": {
           "installation": "AVAILABLE",
           "authentication": "ON_INSTALL"
         },
         "category": "Productivity"
       }
     ]
   }
   ```

   如果文件已经存在，只把 `remote-connector` 这个对象添加到现有 `plugins` 数组里。不要覆盖已有 marketplace 条目。`source.path` 保持为 `./plugins/remote-connector`，不要改成绝对路径。

3. 在 Codex 中安装或刷新插件。

   ```bash
   codex plugin add remote-connector@personal
   ```

   安装后，Codex 会把插件复制到类似下面的 cache 路径：

   ```text
   ~/.codex/plugins/cache/personal/remote-connector/0.1.0+codex.20260607103220/
   ```

   这个 cache 应视为只读生成物。更新插件时，请修改或 `git pull` `~/plugins/remote-connector` 中的源码，再运行 `codex plugin add remote-connector@personal`，然后开启新的 Codex thread。

4. 开启新的 Codex thread。

   新安装或刷新的插件 skill 会在新 thread 开始时生效。新 thread 中调用：

   ```text
   @Remote-Connector devbox
   ```

## 快速开始

1. 在本地 SSH config 中添加远程机器。

   ```text
   Host devbox
     HostName devbox.example.com
     User you
     IdentityFile ~/.ssh/id_ed25519
   ```

2. 确认普通 SSH 可以连接。

   ```bash
   ssh devbox
   ```

3. 运行 Remote Connector。

   安装插件后，可以在 Codex 中调用：

   ```text
   @Remote-Connector devbox
   @Remote Connector devbox
   ```

   也可以在本仓库中直接运行脚本：

   ```bash
   scripts/codex-remote-connector.sh devbox
   ```

   再次运行同一条命令会检查远程安装、反向隧道和登录状态，并自动修复缺失项。

   支持可选的位置端口参数：

   ```text
   @Remote-Connector REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
   ```

4. 完成 device login。

   当命令输出设备认证 URL 和验证码时，保持命令运行。用本地浏览器打开 URL，输入验证码，并用 Codex desktop 使用的同一个账号和 workspace 完成登录。

5. 在 Codex desktop 中添加 SSH connection。

   打开 **Codex > Settings > Connections > SSH**，使用脚本输出的字段手动添加或启用 SSH host。插件安装和 `@Remote-Connector` 执行不会自动保证该 host 已出现在 Connections 里；如果 Codex 可以操作 desktop UI，也可以让它按这些字段尝试自动添加。

   ```text
   SSH host/alias: devbox
   Remote Codex binary: ~/.codex/bin/codex
   Remote Codex home: ~/.codex
   Reverse proxy on remote: http://127.0.0.1:17890
   ```

6. 在 Codex 中选择远程项目目录并启动 thread。

## 脚本用法

```bash
scripts/codex-remote-connector.sh [options] REMOTE_SSH_MACHINE [REMOTE_FORWAR_PORT] [LOCAL_FORWARD_PORT]
```

`REMOTE_SSH_MACHINE` 必须是 `~/.ssh/config` 中简单明确的 SSH `Host` alias。出于安全考虑，alias 只允许字母、数字、点、下划线和连字符。`REMOTE_FORWAR_PORT` 默认是 `7890`，`LOCAL_FORWARD_PORT` 默认是 `17890`。

参数：

| 参数 | 说明 |
| --- | --- |
| `--dry-run` | 只打印将执行的 SSH 和 SCP 命令，不真正连接远程机器。 |
| `--ssh-config PATH` | 从指定 SSH config 文件读取 host 条目。 |
| `--install-script PATH` | 使用指定安装脚本，而不是默认的 `./scripts/codex_install.sh`。 |
| `--remote-bind HOST:PORT` | 反向隧道在远程机器上的绑定地址，默认 `127.0.0.1:17890`。 |
| `--local-proxy HOST:PORT` | 反向隧道转发到的本地代理地址，默认 `127.0.0.1:7890`。 |
| `--skip-install` | 不创建 `~/.codex`，不复制安装脚本，也不安装 Codex。 |
| `--skip-tunnel` | 不启动反向 SSH 隧道。 |
| `--skip-login` | 不运行 `codex login --device-auth`。 |
| `-h`, `--help` | 显示帮助。 |

常用示例：

```bash
# 预览将执行的操作，不连接远程机器。
scripts/codex-remote-connector.sh --dry-run devbox

# 使用不同的本地代理端口。
scripts/codex-remote-connector.sh devbox 8080

# 同时指定本地代理端口和远程绑定端口。
scripts/codex-remote-connector.sh devbox 8080 18888

# 远程机器已经安装并登录 Codex。
scripts/codex-remote-connector.sh --skip-install --skip-login devbox

# 只安装和登录，隧道由你自己管理。
scripts/codex-remote-connector.sh --skip-tunnel devbox
```

## 安装脚本说明

`scripts/codex_install.sh` 会在远程用户的 Codex home 下安装独立版 Codex CLI：

```text
~/.codex/bin/codex
~/.codex/packages/standalone/
```

手动运行安装脚本时支持这些环境变量：

| 变量 | 说明 |
| --- | --- |
| `CODEX_RELEASE` | 要安装的 Codex 版本，默认 `latest`。 |
| `CODEX_NON_INTERACTIVE` | 设置为 `1`、`true` 或 `yes` 时跳过交互提示。 |
| `CODEX_HOME` | Codex home 目录，默认 `~/.codex`。 |
| `CODEX_INSTALL_DIR` | 可见 `codex` 命令的安装目录，默认 `$CODEX_HOME/bin`。 |

如果远程机器无法访问 GitHub releases，可以用其他方式在远程机器安装 Codex，确认 `~/.codex/bin/codex` 存在后再运行：

```bash
scripts/codex-remote-connector.sh --skip-install devbox
```

## 安全说明

- Remote Connector 只使用 `ssh`、`scp` 和标准 shell 工具。
- 它要求本地已经有可用的 SSH alias。
- 默认反向隧道只绑定远程机器的 `127.0.0.1`，不会公开暴露。
- 不要把 Codex app server transport 或代理端口直接暴露到共享网络或公网。
- 不要分享 device login code、passkey、密码或 MFA secret。
- 远程机器应当被视为一台能访问你的代码和凭据的开发机器。

## 排障

### `Host 'devbox' not found in ~/.ssh/config`

请在 `~/.ssh/config` 中添加明确的 `Host devbox` 条目。只有 `Host *` 这类 pattern 条目是不够的。

### 终端里 SSH 可以连接，但脚本找不到 host

显式传入 SSH config：

```bash
scripts/codex-remote-connector.sh --ssh-config ~/.ssh/config devbox
```

### 安装脚本无法下载 Codex

确认远程机器有 `curl` 或 `wget`，并且可以访问 GitHub releases。如果你的环境需要特殊安装路径，可以手动安装 Codex，然后用 `--skip-install` 重新运行。

### 远程 Codex 无法访问互联网

保持反向 SSH 隧道运行，并确认本地代理可以从本地机器访问。如果你的本地代理不是 `127.0.0.1:7890`，请传入 `REMOTE_FORWAR_PORT` 或 `--local-proxy HOST:PORT`。

### Device login 一直卡住或没有完成

保持 SSH login 命令打开，直到浏览器认证完成。确认你登录的是 Codex desktop 使用的同一个 ChatGPT 账号和 workspace。

### Codex desktop 无法启动远程连接

检查 connection 字段：

```text
SSH host/alias: the same alias used by ssh
Remote Codex binary: ~/.codex/bin/codex
Remote Codex home: ~/.codex
Reverse proxy on remote: http://127.0.0.1:17890
```

然后 SSH 到远程机器验证：

```bash
~/.codex/bin/codex --version
```

## 本地校验

预览端到端操作：

```bash
scripts/codex-remote-connector.sh --dry-run devbox
```

检查 shell 语法：

```bash
bash -n scripts/codex-remote-connector.sh
```

检查插件 manifest 是否为合法 JSON：

```bash
python3 -m json.tool .codex-plugin/plugin.json
```

## 发布前检查

发布到 GitHub 前建议检查：

- 设置最终仓库名和描述。
- 如果不希望发布者显示为 `Local`，修改 `.codex-plugin/plugin.json` 中的 author。
- 添加与 manifest 中 `MIT` 对应的 `LICENSE` 文件。
- 如果希望用户更快理解流程，可以添加截图或简短终端录屏。
- 修改脚本行为后打 tag。
- 请测试者在一次性的 SSH host 上同时测试插件调用和直接脚本调用。

## License

插件 manifest 当前声明为 `MIT`。如果希望 GitHub 自动识别许可证，请添加 `LICENSE` 文件。
