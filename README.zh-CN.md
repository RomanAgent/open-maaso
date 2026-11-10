<div align="center">

<img src="docs/media/open-maaso-hero.svg?v=white-frost-transparent-logo" alt="open-maaso — 让 Agent 拥有声音、形象与工作空间" width="100%" />

**默认在本机运行的陪伴工作空间。**

本地登录 · 本机数据 · 系统语音 · 离线小游戏与小程序

[English](README.md) · [开始使用](docs/getting-started.md) · [离线架构](docs/offline-edition.md) · [参与贡献](CONTRIBUTING.md)

</div>

## 原版界面，本地运行

**沿用原版 Maaso 的应用入口、路由、页面布局与交互。** Home、对话、小游戏、小程序、陪玩、商店、个人工坊、资料、记忆和设置继续使用原页面。Home 背景与登录呈现保留原版 Coastal V4 资源，人物替换为免费 Pixiv VRM；在原设置页配置自己的 API Key。

本地登录与数据保存不需要 Maaso 后台。原服务通过本地适配器处理账号、资料、作品、目录与技能，对话和记忆继续使用原账号隔离的 Sembast 数据库。

| 测试账号 | 内容 |
| --- | --- |
| 用户名 | `test` |
| 密码 | `test123456` |

原登录输入框已预填。这是本地演示身份，不能替代设备的数据保护。

## 产品能力

| 体验 | 实现 |
| --- | --- |
| Home 与对话 | 原版页面、HomeController 和串行 AgentRuntime 回合 |
| 人物 | 免费 Pixiv VRM，复用原 UnityAvatarRuntime |
| 模型配置 | 原设置页配置区，12 类厂商，Key 保存于安全存储 |
| 语音 | 手机已安装的音色生成本地 PCM，复用原播放队列与人物口型时序 |
| 小游戏与小程序 | 原列表、创作入口、播放器和陪玩控件；作品保存在本机 |
| 商店与工坊 | 原页面，本地目录、提示词技能与作品记录 |
| 资料与记忆 | 原资料、记忆和账号隔离的数据服务 |
| 硬件 | 原 BLE 小程序和共享设备连接服务 |
| 模型调用 | 由设置中的厂商与 Key 配置决定，无会员卡、套餐入口或会员门槛 |

大模型请求只使用本机保存的端点、模型与 Key。配置不完整时提示补全；厂商调用失败时不会回退到 Maaso 代理或内置本地大模型。远程大模型请求仍需网络。尚无本地实现的云端操作会明确返回不可用。具体边界见[本地适配说明](docs/offline-edition.md)。

## 配置自己的大模型

进入**设置 → 模型配置**，可选择 OpenAI、Anthropic Claude、Google Gemini、DeepSeek、通义千问、豆包、Kimi、智谱 GLM、硅基流动、Groq、Ollama 或自定义 OpenAI 兼容端点。确认地址与模型，填写 Key 并保存，配置有效后自动使用。没有 Cloud off 开关或本地大模型兜底；保存配置不会自动发起健康探测。

API Key 按账号保存在设备安全存储，不写入对话、作品或 Git，请求时仅发送到你选择的模型端点。远端地址使用 HTTPS；明确配置的本机回环服务可使用 HTTP 且无需 Key。手机上的 `127.0.0.1` 指手机自身，模型可用性取决于你的厂商账号。

对话链路为：**语音识别或文字 → 用户配置的大模型 API → 手机本地 TTS → 语音与人物口型**。系统已安装的音色在本机合成 PCM/WAV，再交给原有语音队列、播放、暂停/恢复和取消机制。不会调用云 TTS 或自动下载音色。语音识别或本地音色不可用时仍可文字交流；是否播放声音由应用声音设置控制。

## 快速开始

记录的工具链为 **Flutter 3.47.2 / Dart 3.13.2**，原生人物使用 **Unity 6000.5.2f1**。开发依赖的安装阶段可能需要联网。

```bash
git clone https://github.com/RomanAgent/open-maaso.git
cd open-maaso
flutter pub get
flutter test test/local_test_auth_client_test.dart test/local_original_backend_test.dart \
  test/local_skill_marketplace_test.dart test/original_ui_local_catalog_test.dart \
  test/local_edition_model_integration_test.dart
```

按[使用指南](docs/getting-started.md)与[原生打包说明](docs/offline-platforms.md)准备 Unity 导出及签名，再执行 `flutter run -d <device-id>`。默认入口是**原版 `MaasoApp`**，`MAASO_OFFLINE_EDITION=true` 选择本地服务适配器。

## Maaso 历史产品实拍 · 2026-11-01

下面是较早 Maaso 参考构建的真实 iPhone 截图，展示原有人物、房间与游戏控制。它们是历史产品示例，**不代表新版离线入口的实机验收结果**。离线人物采用独立声明的免费 Pixiv 模型。

<table>
  <tr>
    <td align="center" width="50%"><strong>Home · 与 Agent 相伴</strong><br/><a href="docs/media/showcase/home.png"><img src="docs/media/showcase/home.png" alt="iPhone 上的 Maaso Home，包含角色、房间和输入框" width="260"/></a><br/><sub>在同一个空间中承载对话与角色呈现。</sub></td>
    <td align="center" width="50%"><strong>小游戏创作 · 从一句话开始</strong><br/><a href="docs/media/showcase/game-request.png"><img src="docs/media/showcase/game-request.png" alt="在真实 Maaso 输入框中描述火箭小游戏需求" width="260"/></a><br/><sub>通过对话描述想做的小游戏。</sub></td>
  </tr>
  <tr>
    <td align="center" width="50%"><strong>雷霆战机 · 纵版射击</strong><br/><a href="docs/media/showcase/space-shooter.png"><img src="docs/media/showcase/space-shooter.png" alt="雷霆战机在 Maaso iPhone 播放器中运行，飞机和弹幕可见" width="260"/></a><br/><sub>真实运行的战机小游戏，展示飞机与弹幕。</sub></td>
    <td align="center" width="50%"><strong>贪吃蛇 · 经典玩法</strong><br/><a href="docs/media/showcase/gameplay.png"><img src="docs/media/showcase/gameplay.png" alt="Maaso iPhone 播放器中的贪吃蛇、食物与暂停重开控件" width="260"/></a><br/><sub>在播放器中游玩、暂停与重新开始。</sub></td>
  </tr>
  <tr>
    <td align="center" width="50%"><strong>小游戏陪玩 · Play together</strong><br/><a href="docs/media/showcase/game-companion.png"><img src="docs/media/showcase/game-companion.png" alt="从战机小游戏内打开的真实 Play together 陪玩面板" width="260"/></a><br/><sub>在游戏内设置语音、聊天频率与提示方式。</sub></td>
    <td align="center" width="50%"><strong>我的小游戏库</strong><br/><a href="docs/media/showcase/mini-games.png"><img src="docs/media/showcase/mini-games.png" alt="Maaso 我的游戏中真实保存的小游戏列表" width="260"/></a><br/><sub>集中查看并重新打开已保存的作品。</sub></td>
  </tr>
</table>

<sub>创作图展示请求输入，战机和贪吃蛇是已有作品；陪玩图展示设置面板，没有记录完整语音或自主操作过程。</sub>

[拍摄说明与素材署名 →](docs/media/showcase/README.md)

## 验证与下一步验收

本地持久化、仅 API 配置、凭据隔离、账号切换后的主题绑定、本地语音和回合取消均有聚焦自动化测试。随附人物包含项目自制的 `standard_walk` 动作；此前缺少该状态会导致 Home 入场返回 `walk_unavailable`，并使 Agent 空间中的人物滑行。Receiver / Play Mode 检查覆盖修复后的入场、渲染完成与取消，详见[行走动作来源与验证](docs/avatar/free-vrm-walk.md)。这些检查不代表手机实机验收录像。

待验收项包括：包含本地 Unity 场景的干净原生构建、签名移动端 Release 安装和无调试器冷启动、真实设备系统 TTS 与通知送达、兼容 BLE 硬件、使用自有 Key 的在线模型调用，以及原生播放器的网络与状态行为。尚未声称完整复刻旧版全部能力。具体边界见[离线版说明](docs/offline-edition.md)；较早的[验证记录](docs/verification.md)对应最初源码导出。

## 许可证与贡献

自有源码采用 [MIT 许可证](LICENSE)。随附 Pixiv 人物使用 **VRM Public License 1.0 及文件内嵌许可设置**，独立于 MIT。第三方依赖和原生 SDK 保留各自条款，包括 BLE 包的商业条件与 FFmpeg 的 LGPL 义务；分发构建产物前请阅读 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

密钥和签名材料保存在 Git 之外。开发和反馈请遵循 [SECURITY.md](SECURITY.md)、[CONTRIBUTING.md](CONTRIBUTING.md)，并通过 [Issues](https://github.com/RomanAgent/open-maaso/issues) 提交可复现问题。
