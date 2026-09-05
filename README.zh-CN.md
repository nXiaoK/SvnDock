# SvnDock

[English](README.md)

![版本](https://img.shields.io/badge/version-0.3.0-blue)
![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 工具链](https://img.shields.io/badge/Swift_6-toolchain-orange?logo=swift)
![许可证](https://img.shields.io/badge/license-MIT-green)

SvnDock 是一款原生 macOS SVN 客户端，专注多工作副本管理与 Finder
右键集成。它把常用 SVN 操作放到文件旁边，不需要依赖 IDE。SVN 工作副本中也可以
同时存在 Git 仓库：SvnDock 不会调用 Git，也不会主动修改 `.git`。

> SvnDock 目前处于开发预览阶段。0.3.0 已覆盖主要工作副本操作和 Finder Sync
> 扩展，但尚无 Developer ID 签名并经过 Apple 公证的公开安装包，请从源码构建后
> 试用。

## 主要功能

- 登记多个 SVN 工作副本，应用本身不设置数量上限。
- 查看本地状态、筛选变更文件、检查文本 Diff 和浏览仓库历史。
- 单击文件即可更新右侧差异，双击可在独立窗口查看；支持 ⌘／Shift 多选和键盘切换。
- 差异支持合并、并排及原文视图，显示真实新旧行号，可跳转变更块、自动换行
  并复制完整补丁，字号可在 10–20 pt 之间调整。主界面与独立差异窗口使用同一套显示逻辑。
- 提交时点击 **放大查看**（⇧⌘F）可专注阅读差异并切换文件；点击 **返回提交**
  或按 Esc 返回，提交说明和文件勾选会保留。
- 单击历史记录即更新下方变更文件，单击变更文件即切换历史差异；双击可在独立窗口
  放大查看。支持
  新增、删除、替换、复制／移动来源和目录属性。[使用说明](Docs/History-Review.md)。
- 支持 Update、Commit、Add、Revert、Resolve、Cleanup，以及安全合并
  `svn:ignore` 规则。
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
提交目录仍会包含其子项，因此其中的缺失文件也需要先处理；SvnDock 不会自动更改
这些文件的添加、删除计划。

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
| Intel Mac | 本机构建脚本支持 `x86_64`，尚未在 Intel 真机验证 |
| Subversion | 已使用 SVN 1.14 测试，其他版本暂未验证 |
| 界面语言 | 简体中文 |
| 分发方式 | 源码构建、本机 ad-hoc 测试构建 |

SvnDock 会依次检查 Homebrew、MacPorts 和系统中的常见 `svn` 路径，再检查
`PATH`。开发环境也可以通过 `SVNDOCK_SVN_PATH` 指定绝对可执行文件路径。

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

系统中最好只保留一份可被发现的 SvnDock。如果 Finder 仍加载旧扩展，可先关闭再
重新启用扩展，必要时再重启 Finder。

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
