# Codex 上下文

一个原生 macOS 伴随工具：不用在聊天里发送配置指令，即可为 Codex 对话或项目选择上下文策略，并查看 Token 用量与账户额度。

[下载试用版](https://github.com/yimengbenxin/codex-context-menu/releases/tag/v0.6.4) · [反馈问题](https://github.com/yimengbenxin/codex-context-menu/issues) · [English](README.en.md)

**非 OpenAI 官方产品，未获 OpenAI 背书。0.6.4 是兼容范围有限的实验性试用版，不是适用于所有 Codex 安装的通用补丁。**

## 为什么做这个工具

长任务需要调整上下文，但不应该为此向项目聊天反复发送“修改上下文”的指令。同一项目有多个对话时，仅选择文件夹也不够准确。

本工具把“目标对话”“保存的设置”和“实际运行窗口”分开呈现；通过对话深度链接精确定位，在两轮对话之间加载设置，不打断正在生成的回复。

## 已发布功能

| 功能 | 说明 |
| --- | --- |
| 官方默认 | 清除所选范围的覆盖，继承上级配置及官方参数；不写死 272K 或模型 |
| 自定义 | 输入整数 K；1 K = 1,000 tokens；留空清除覆盖 |
| 自适应 | 依据官方模型元数据生成初始档、中间档和上限，自动压缩成功后判断是否升档 |
| 对话级 / 项目级 | 默认可选“仅此对话”；项目级需明确选择，不把对话覆盖复制给其他对话或新分叉 |
| 识别当前对话 | 通过本地桌面 IPC 和会话元数据定位；多窗口无法唯一判断时使用深度链接 |
| 深度链接 | 支持粘贴 `codex://threads/<UUID>` 并定位；提供原生 ⌘V、⌘A 等编辑操作 |
| 下一轮加载 | 接入后，默认、自定义切换及自适应升档无需逐次重启 Codex |
| 用量概览 | 查看本地近七天 Token 统计，手动读取官方账户额度；自动额度刷新默认关闭 |
| 安装与恢复 | 安装前检查、旧安装备份、失败回滚及官方启动环境恢复 |

**不包含换模型压缩、调整压缩推理强度或压缩加速插件。** 模型请求和压缩仍由官方后端执行。

## 安装要求与兼容范围

当前安装包仅支持：

- **macOS 14 或更新版本、Apple Silicon。**
- **Python 3.11+**：现有 Codex 管理的 Python，或 `/opt/homebrew/bin/python3`、`/usr/local/bin/python3`。
- 已测试的官方 **0.159.2 CLI / Node 组合**，且两个程序的哈希匹配 [compatibility.json](macos/Resources/adaptive/compatibility.json)。
- 官方程序位于以下布局：

```text
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
```

**其他版本、不同 Codex.app 布局、Intel Mac、Windows 和 Linux 暂不支持。** 安装前检查不通过会退出，不进行安装复制或持久配置变更。工具不会下载、修改或重新签名 OpenAI 程序。普通使用无需另装 Python 库，随包提供带许可证的 TOML 编辑库。

### 下载与安装

到 [0.6.4 发布页](https://github.com/yimengbenxin/codex-context-menu/releases/tag/v0.6.4) 下载：

- `CodexContextMenu-0.6.4-macOS-arm64.dmg`：磁盘映像。
- `CodexContextMenu-0.6.4-macOS-arm64.zip`：压缩包，与 DMG 包含相同应用和安装程序。
- `v0.6.4-SHA256.txt`：文件校验值。

1. 校验下载文件，解压 ZIP 或挂载 DMG。
2. 保持 `Install.command`、`install_local.py` 和 `CodexContextMenu.app` 在同一目录，双击 `Install.command`。
3. 安装程序检查兼容性、备份旧安装，将工具放入 `~/Applications`，建立自己的登录启动项并启用启动接入；不需要管理员密码。
4. **整个 Codex 首次启用本工具的启动接入时，完整退出并重新打开一次。不是每个对话首次使用都要重启。** 更新运行组件也需要重新加载新组件；普通预算切换不需要重启。
5. 打开“Codex 上下文”，识别或定位目标，选择范围和策略，保存后在下一轮检查“最近运行窗口”。

应用为本地临时签名，**未使用 Apple Developer ID 签名及公证**。核对来源和校验值后，按系统提示手动批准运行。安装程序不关闭 Gatekeeper、不静默移除隔离标记，也不绕过系统警告。

只读安装前检查：

```sh
python3 install_local.py ./CodexContextMenu.app --check
```

签名检查使用临时副本，仅移除 Finder 装饰及资源分支元数据，保留隔离标记；不会修改下载的应用或持久安装状态。

## 使用方式与自适应逻辑

### 精确选择目标

点击“识别当前对话”，或者将对话深度链接粘贴到输入框，再点击“定位链接”。核对目标和修改范围：

- **仅此对话**：只保存该对话的设置。
- **项目级**：明确修改所选项目的配置，可能影响继承项目设置的其他对话。

保存成功只表示设置已写入，**不代表运行时已经加载**。下一轮以实际运行反馈为准。正在生成、存在其他订阅者或无法完整保留的权限状态时，可能无法立即重新加载。

### 自适应如何升档

三个档位来自官方模型元数据：**官方初始值 → 初始值与上限的算术中间值 → 官方上限**，不是固定的 272K / 487K / 872K。

自动压缩成功后，依据保留比例判断：

- 保留比例 **≥65%**：升一档。
- **≥45% 且 <65%**：连续两次满足条件后升一档。
- **<45%**：重置连续计数。
- 手动压缩或失败压缩：不升档。

满足条件后，新档位在**下一轮对话**加载，不改变本轮正在生成的回复，也不必再等一次压缩。

从自定义切回自适应：恢复同一范围、模型及配置版本下有效的历史自适应档位；没有有效状态时，从官方初始档开始。**不会把自定义值当作自适应起点继续向上跳。**

### 数值与缓存

输入 485 表示原始预算 485,000 tokens，但实际窗口受到官方有效窗口比例和模型上限约束，不一定显示为 485,000。默认模式不固定任何数值。

会话重载可能暂时降低缓存命中率，**不能承诺零缓存成本**。已观察到切换后命中率短暂下降、后续请求恢复较高复用，但这不是严格控制变量的因果测试。

## 架构与工作流程

```mermaid
flowchart LR
  User[用户] --> UI[原生设置窗口与菜单栏]
  IPC[本地桌面 IPC 和会话元数据] --> UI
  UI --> Config[配置权威模块]
  Config --> State[对话状态或指定项目配置]
  State --> Policy[自适应生命周期控制器]
  Policy --> Native[未修改的官方签名后端]
  Native --> Logs[本地 Token 与生命周期事件]
  Logs --> UI
  UI --> Stats[CodexBar 本地统计：禁止联网]
  UI -->|手动或主动开启刷新| Quota[官方额度：OpenAI 端点]
  Tests[单元和隔离运行测试] --> Package[源码与发布包]
  Package --> User
```

控制器复用官方会话读取和恢复机制，由原生后端重建空闲会话缓存；不会另写一套模型执行器。上下文策略不改模型或推理强度。

## 隐私、权限与网络

- 上下文控制器未添加遥测、远程控制监听、凭据共享或聊天上传功能。
- 为识别对话和显示用量，需要读取本地会话元数据与日志；**不编辑聊天历史、SQLite、官方模型缓存或官方应用文件**。
- 对话设置写入 `$CODEX_HOME/context-menu/threads`；项目级明确写入所选 `.codex/config.toml`，带版本检查和备份；不修改全局 TOML。
- 有界的 `runtime-events.jsonl` 只记录白名单生命周期元数据，不记录消息内容、工具结果或凭据。
- 启动接入修改四个用户级启动环境变量，并保存原值以便恢复；不修改官方应用包。
- **本地 Token 统计禁止联网。账户额度查询不是离线操作**：固定版本 CodexBar 使用已有认证访问官方 OpenAI 端点，可能进行正常 OAuth 刷新；没有浏览器 Cookie 回退，自动额度刷新默认关闭。
- 正常 Codex 请求保留官方自身的网络行为。本工具不是离线 Codex，也不能提供“整个系统绝无风险”的保证。
- 发布包不包含本机私人日志、聊天记录、登录凭据或官方运行程序。

## 验证结果与已知限制

0.6.4 发布验证包含 **61 项单元检查**：22 项 Swift、23 项 Node、11 项项目配置、3 项对话配置和 2 项安装器检查；另有隔离原生生命周期测试、签名与安装前检查、发布资产下载及 SHA-256 核对。

已验证：

- 隔离合成响应环境中的默认 / 自定义 / 自适应、恢复、重启及分叉，历史前缀保留和 SQLite 完整性。
- 本机桌面 485K → 315K → 485K 切换，官方进程不重启；有效窗口随下一轮变化。
- 实际官方桌面工具调用，以及真实剪贴板粘贴和链接定位；不是用直接设置输入框值替代粘贴测试。

**尚未证明**：真实超长对话自适应升档的完整桌面验收、所有插件兼容性及长期稳定性。合成生命周期测试不是模型压缩速度或质量评测。

当前为菜单栏伴随应用，**Dock 常驻及完整缩小/关闭体验、菜单栏直接选择三种策略、双击图标拉到前台**属于后续迭代，不包含在本次发布中。

## 开发与打包

需要 Xcode 命令行工具和 Swift 5.10+；测试还需要 Node 与 Python 3.11+。

```sh
swift test --package-path macos
node --test macos/Tests/adaptive.test.mjs macos/Tests/privacy-boundary.test.mjs
python3 -B -m unittest discover -s macos/Tests -p test_context_config.py
python3 -B -m unittest discover -s macos/Tests -p test_thread_settings.py
python3 -B -m unittest discover -s macos/Tests -p test_installer.py
bash scripts/build_release.sh 0.6.4
```

可选原生夹具：在隔离环境安装 `requirements-test.txt`，具备受支持的官方程序和模型元数据后，运行 `python3 -B macos/Tests/test_adaptive_boundary.py`。它使用本地回环上的合成响应，不代表真实模型的质量和速度。

GitHub 源码归档包含维护源码及依赖许可，不包含私人验收日志。ZIP / DMG 不捆绑 Python 或官方 Codex 运行时。

## 卸载与恢复

可先切回默认以清除所选覆盖，再恢复官方启动环境：

```sh
"$HOME/Library/Application Support/CodexContextTool/backend" --restore-official
launchctl bootout "gui/$(id -u)/local.wen.CodexContextMenu"
```

将伴随应用和 `~/Library/LaunchAgents/local.wen.CodexContextMenu.plist` 移到废纸篓，确认恢复正常后再处理备份。卸载不会自动删除聊天历史、项目备份或已保存的覆盖设置。

## 许可证与反馈

采用 MIT，保留上游 [Codex Token Overlay](https://github.com/soleillevant0125/codex-token-overlay) 的许可与署名。依赖 CodexBar 0.69.0 和 tomlkit 0.13.3 同为 MIT，见 [第三方声明](docs/THIRD_PARTY_NOTICES.md)。不分发 OpenAI 软件。

反馈时请提供平台、应用版本及脱敏的问题描述，**不要上传凭据、SQLite 数据库或真实聊天日志**。
