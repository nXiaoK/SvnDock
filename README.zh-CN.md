# SvnDock

[English](README.md)

![版本](https://img.shields.io/badge/version-0.4.0-blue)
![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 工具链](https://img.shields.io/badge/Swift_6-toolchain-orange?logo=swift)
![许可证](https://img.shields.io/badge/license-MIT-green)

SvnDock 是一款原生 macOS SVN 客户端，专注多工作副本管理与 Finder
右键集成。它把常用 SVN 操作放到文件旁边，不需要依赖 IDE。SVN 工作副本中也可以
同时存在 Git 仓库：SvnDock 不会调用 Git，也不会主动修改 `.git`。

> SvnDock 目前处于开发预览阶段。0.4.0 已覆盖主要工作副本操作和 Finder Sync
> 扩展。[GitHub Releases](https://github.com/nXiaoK/SvnDock/releases) 提供自动构建的
> arm64、x64 DMG 测试包，使用可跨账号运行的 ad-hoc 签名，尚未配置 Developer ID
> 签名与 Apple 公证。

## 主要功能

- 登记多个 SVN 工作副本，应用本身不设置数量上限。
- 分别展示本地路径、仓库 URL 和根目录基线。点击 **检查服务器** 可查看传入的内容
  及属性更新，不会更新本地文件或改变本地状态／Finder 角标；结果带检查时间，
  本地刷新或写操作后会提示需要重新检查。
- 设置中可独立选择登录时启动和显示菜单栏图标。菜单栏支持查看状态、切换副本、
  刷新、更新、提交、历史及 Finder／设置入口，关闭主窗口后仍可使用。
- 查看本地状态、筛选变更文件、检查文本 Diff 和浏览仓库历史。
- 单击文件即可更新右侧差异，双击可在独立窗口查看；支持 ⌘／Shift 多选和键盘切换。
- 本地目录可直接查看属性变化；未纳管 UTF-8 文本无需先添加就能只读预览，最大 1 MiB，
  二进制、不支持的类型、缺失和读取失败分别提示。差异模式和字号会保留。
- 右键添加和还原保留多选并显示实际处理数量；多选检查器展示状态统计和可用动作。
- 差异支持合并、并排及原文视图，显示真实新旧行号，可跳转变更块、自动换行
  并复制完整补丁，字号可在 10–20 pt 之间调整。主界面与独立差异窗口使用同一套显示逻辑。
- 提交时点击 **放大查看**（⇧⌘F）可专注阅读差异并切换文件；点击 **返回提交**
  或按 Esc 返回，提交说明和文件勾选会保留。
- 提交草稿按工作副本保留说明、勾选路径和预览位置，关闭窗口或重启后可恢复。
  提交清单支持路径筛选和仅看已包含项目；新变更不会自动加入已保存的勾选范围。
- 历史记录支持说明、作者或版本号筛选，并可同时限定作者；筛选范围明确为已载入记录。
  输入 `r123` 或 `123` 可直接查看仓库提交详情。历史每页 100 条按更早修订继续读取，
  不再限制为 1,000 条；读取失败保留已有记录并重试同一页。
- 单击历史记录即更新下方变更文件，单击变更文件即切换历史差异；双击可在独立窗口
  放大查看。支持
  新增、删除、替换、复制／移动来源和目录属性。[使用说明](Docs/History-Review.md)。
  历史记录和变更文件使用柔和的蓝色选中背景，并在浅色与深色模式下保持文字清晰。
- 冲突审阅页列出准确路径、内容／属性／结构类型和当前差异；混合选择保留其中的
  冲突范围，整文件替换需明确勾选确认。处理后重新核验所选节点，并记录未完成或
  待确认结果，不自动重试。[冲突处理说明](Docs/Conflict-Review.md)。
- 支持 Update、Commit、Add、Revert、Resolve、Cleanup，以及安全合并
  `svn:ignore` 规则。
- 底部操作记录保留本次运行最近 30 条更新、提交与冲突处理结果，逐个显示工作副本的结果，
  可展开并复制已脱敏的详情。批量更新遇到单个副本失败后继续处理其他副本；
  提交中断或结果不确定时保留草稿，提示先检查仓库历史再手动重试。
- 通过 Finder 右键菜单执行常用操作。
- Finder 只读取状态缓存来展示角标，不会在 Finder 进程中运行 SVN。
- 同一工作副本的写操作会串行执行，App 与可选 Agent 之间也使用同一套协调机制。
- 使用 `Foundation.Process` 和独立参数数组调用 SVN，不经过 shell。
- 认证交由已安装的 SVN 客户端及其配置处理；SvnDock 不接收或保存密码。

切换预览选择会取消过时的差异请求。大状态列表和差异视图复用数据，Finder
复用未变化的状态快照。测试场景、验证结果及内存限制见
[代码审查与性能测量记录](Docs/Audit-2026-09/README.md)。

大批量提交使用临时路径清单，仍保持为一次 SVN 提交。本地缺失项目不会出现在
可提交清单中：请根据实际情况恢复文件、取消添加计划，或标记为 SVN 删除后重试。
提交仅处理勾选节点，目录属性不会带入未勾选的子文件修改；新增子文件需要同时勾选
尚未提交的父目录。删除目录仍会删除仓库中的整个目录树，复制目录会保留来源结构
和历史，未勾选的本地子项修改继续留在工作副本中；提交清单会说明这些目录操作范围。
软件在工作副本锁内重新检查 SVN 状态和父目录依赖，再执行一次提交。文件型 external
需单独处理。SvnDock 不会自动更改文件的添加、删除计划。

已提交的文件或目录在本地删除后，可右键选择 **标记为 SVN 删除…**，也可使用
右侧检查器或缺失提示栏中的删除入口。支持多选和合并显示的缺失目录。
标记后 SVN 状态从“本地缺失”（`!`）变为“已删除”（`D`），再提交这次删除，
仓库中的对应项目才会移除；仅对本地缺失项目执行更新可能会恢复文件。
还原缺失或待删除目录时会恢复其内容；普通目录属性的还原只处理目录自身。

如果目录在本地添加后从未提交，随后又从磁盘删除，可点击缺失提示栏中的
**清理未提交的添加记录**，或右键该目录选择 **清理缺失的添加记录…**。
软件会先确认所选根路径仍是“缺失的待添加项目”，再递归取消添加计划；不会删除
磁盘内容或提交仓库变更。若混有已纳管项目，清理会停止，此时请只选择需要处理的
待添加目录。缺失目录默认合并显示，可用 **显示明细** 或路径搜索查看子项。

## 兼容性

| 项目 | 支持情况 |
| --- | --- |
| macOS | 14 或更高版本 |
| Apple Silicon | 已测试 |
| Intel Mac | 原生 `x86_64` CI 构建与测试，尚未验证 Intel 桌面界面 |
| Subversion | 已使用 SVN 1.14 测试，其他版本暂未验证 |
| 界面语言 | 简体中文 |
| 分发方式 | 源码、本机测试 App、arm64/x64 DMG 预发布包 |

SvnDock 会依次检查 Homebrew、MacPorts 和系统中的常见 `svn` 路径，再检查
`PATH`。开发环境也可以通过 `SVNDOCK_SVN_PATH` 指定绝对可执行文件路径。

## 下载与安装

从 [Releases](https://github.com/nXiaoK/SvnDock/releases) 下载对应架构的 DMG：
Apple Silicon 选择 `arm64`，Intel 选择 `x64`。打开后将 **SvnDock.app** 拖到
**Applications**，推出磁盘映像，再从应用程序文件夹启动。

仍需单独安装 SVN 1.14，例如 `brew install subversion`。测试包尚未经过 Apple
公证，首次打开时 macOS 可能需要用户明确批准。

每次 push 都会构建两种架构，通过验证后将两个安装包及 SHA-256 校验文件一起发布为
预发布版本。触发规则、签名限制和故障排查见
[自动 DMG 发布说明](Docs/GitHub-Releases.md)。

## 构建本机 App

需要：

- 带有 Swift 6 兼容 macOS SDK 的 Apple Command Line Tools
- 本机已安装 Subversion

在仓库根目录执行：

```sh
./Scripts/build-local-signed-app.sh ./dist
```

脚本会生成 `dist/SvnDock.app` 和当前架构对应的压缩包。App 与 Finder
扩展都会使用 ad-hoc 签名，并启用 Hardened Runtime。

该产物只适合本机测试，不是可公开分发的正式版本。它不含发布者身份、
provisioning profile 或公证票据，共享数据路径也会绑定到执行构建的 macOS
账户。请在实际运行它的账户中从可信源码重新构建。完整限制见
[本机 ad-hoc 构建说明](Docs/Local-Signed-Build.md)。

### 启用 Finder 扩展

1. 将构建出的 `SvnDock.app` 移到 `/Applications`，并启动一次。
2. macOS 15：打开“系统设置 → 通用 → 登录项与扩展 → 扩展 → Finder 扩展”。
3. macOS 14：入口也可能位于“隐私与安全性 → 扩展”。
4. 启用 **SvnDock Finder**，打开 SvnDock，并登记一个已有的 SVN 工作副本。

也可从 SvnDock 设置中的 **打开 Finder 扩展设置…** 直接进入系统管理界面。
保持 App 运行，Finder 当前浏览目录的状态会自动刷新：绿色勾表示未修改，
黄色笔表示已修改，红色警告表示冲突，蓝色加号表示已添加；灰色符号区分
未纳管、已忽略、待确认和待刷新。角标位置由 macOS 决定。

右键文件 → **SvnDock**，可以提交本次选择、查看该文件的历史或本地差异。
提交窗口优先勾选本次 Finder 所选文件，并保留草稿中的提交说明；最终提交前
仍可检查和调整。历史详情会优先定位目标文件。未修改文件可查看空差异，
目录差异显示目录自身的属性变更。

自动刷新按 Finder 浏览的目录读取状态，不会将全部未修改文件加入 App 的变更列表。
退出 SvnDock 会停止后台刷新，缓存超过一分钟后显示灰色待刷新状态。

系统中最好只保留一份可被发现的 SvnDock。如果 Finder 仍加载旧扩展，可先关闭再
重新启用扩展，必要时再重启 Finder。

## 自启与菜单栏

打开 **SvnDock → 设置 → 启动与菜单栏**。**登录时启动**通过 macOS 登录项登记
当前应用，并显示系统实际状态；如果需要系统允许，可通过设置中的入口前往处理。
建议先将应用放到 `/Applications` 等固定位置，再开启登录自启。

**显示菜单栏图标**默认关闭，选择会自动保存。菜单显示上次载入的工作副本状态，
点击**刷新状态**可重新扫描。菜单操作沿用主窗口的操作限制，**提交…**会打开原有
提交窗口。关闭后重新打开主窗口会保留当前工作区，不会重复载入登记信息，也不会
增加定时后台扫描。

## 开发

### Swift Package Manager

```sh
swift build --disable-sandbox
swift test --disable-sandbox
swift run --disable-sandbox SvnDockCoreSmoke
```

`swift test` 需要工具链提供 XCTest。冒烟测试默认不会访问真实仓库；只有显式配置
文档中说明的一次性集成测试工作副本时，才会运行真实 SVN 操作。

### Xcode 工程

Xcode 工程由 `project.yml` 生成：

```sh
xcodegen generate
open SvnDock.xcodeproj
```

签名前，请把 `project.yml` 中以下配置替换为自己 Apple Developer Team
拥有的标识：

```yaml
SVNDOCK_BUNDLE_ID_PREFIX: com.yourcompany.svndock
SVNDOCK_APP_GROUP_IDENTIFIER: group.com.yourcompany.svndock.shared
```

App 与 Finder 扩展必须使用同一个已配置的 App Group。Developer ID、App Group
和 Apple 公证是计划采用的正式分发方式，但目前尚未完成公开发行链路验证。

## 项目结构

```text
SvnDockCore/       SVN 命令、XML 解析、进程执行和共享状态
SvnDockCoreTests/  核心 XCTest 测试
SvnDockCoreSmoke/  不依赖 XCTest 的冒烟检查
SvnDockApp/        SwiftUI 主应用
FinderExtension/   Finder Sync 菜单、角标和命令入队
SvnDockAgent/      后台消费者原型，尚未嵌入 App
Docs/              架构和本机构建文档
Scripts/           本机 App 组装脚本
Packaging/         本机构建使用的 entitlements
project.yml        XcodeGen 工程定义
```

进程边界和命令所有权设计见[架构说明](Docs/Architecture.md)。

## 当前限制

- 可以登记已有工作副本，尚未实现 Checkout 和 Import。
- 后台 Agent 已能作为独立可执行文件构建和测试，但尚未嵌入 App，也未通过
  `SMAppService` 注册；Finder 命令目前由前台 App 消费。
- 没有内置凭据编辑器，认证行为由本机 SVN 客户端负责。
- Finder 扩展的生命周期、菜单位置和角标优先级由 macOS 管理，其他 Finder
  扩展可能覆盖同一文件的角标。
- 尚无可跨机器分发的 Developer ID 签名及公证版本。

## 参与贡献与安全问题

欢迎提交可复现的问题报告和范围清晰的 Pull Request。修改代码前请阅读
[CONTRIBUTING.md](CONTRIBUTING.md)。安全敏感问题请按照
[SECURITY.md](SECURITY.md) 私下报告，不要发布到公开 Issue。

后续计划记录在 [ROADMAP.md](ROADMAP.md)，面向用户的变化记录在
[CHANGELOG.md](CHANGELOG.md)。

## 许可证

SvnDock 基于 [MIT License](LICENSE) 开源。
