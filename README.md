# API2Human

**中文** | [English](README.en.md)

macOS 菜单栏实时提词助手：捕获系统音频（对方的声音）→ 本地流式语音识别 → 结合你的**面试者角色卡**调用大模型 → 在悬浮窗里给出可以直接说出口的回答。还支持屏幕圈选（OCR）代码题和项目代码检索。

> ⚠️ **合规提示**：不少公司明确禁止在面试中使用 AI 辅助。请把本项目用于模拟面试、练习、复盘，或在允许的场合使用，并自行承担使用后果。

## 功能

- **听**：Core Audio Process Tap 捕获系统音频，另可录制麦克风用于复盘
- **识别**：本地 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 流式中英文模型，不联网，支持热词
- **答**：问题 + 简历/JD/角色卡 → 大模型流式回答（先结论，再 2–4 个要点，约 200 字），能容忍识别错字
- **防编造**：资料里没有的经历、数字、薪资不会编造，会标出"⚠️ 资料里没有"并给一句诚实的话术
- **即圈即搜**：圈选屏幕上的代码或题目，OCR 后逐行推演，给出"发现的问题"和"在项目里的作用"，并在本地项目目录里检索真实调用链
- **朗读**：系统 TTS 读出回答（自动排除本进程音频，避免被采集回去）
- **复盘**：每轮保存 `system.wav` / `mic.wav` / `transcript.txt`（保存在仓库之外）

## 环境

macOS 14.2+（Core Audio Process Tap）、Apple Silicon、Swift 6 工具链

## 构建与运行

```bash
scripts/fetch-models.sh      # 下载 sherpa-onnx 动态库与中英流式识别模型（不进 git）
scripts/bundle.sh release    # 生成 build/API2Human.app
open build/API2Human.app
swift test                   # 单元测试（需先执行 fetch-models.sh）
```

首次运行需要授予「屏幕录制」「麦克风」「系统音频录制」权限。`bundle.sh` 优先使用本机自签名证书 `API2Human Local Signing`，这样重新打包后系统权限不会失效；没有该证书时退回 ad-hoc 签名（每次打包都要重新授权）。

## 配置大模型（密钥不在仓库里）

在 `~/Library/Application Support/API2Human/llm.json` 中填写：

```json
{
  "baseURL": "https://api.anthropic.com",
  "authToken": "在这里填你的 API Key",
  "model": "你的模型名",
  "maxTokens": 800
}
```

也可以用环境变量：`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`（或 `ANTHROPIC_API_KEY`）/ `API2HUMAN_MODEL`。

接口采用 Anthropic Messages 协议，同时发送 `x-api-key` 和 `Authorization: Bearer`，因此兼容各类 Anthropic 协议网关；支持配置备用接口（fallback）。第三方模型是否提供 Anthropic 兼容端点，请以其官方文档为准。

## 面试者角色卡（`.a2hcard`）

角色卡回答一个问题：**"在面试里，我能真实地说出口哪些关于我自己的话？"** 它是 UTF-8 纯 Markdown 文件，把简历、项目、笔记整理成可引用的事实，并标出能力边界（熟练 / 用过 / 了解或没用过）和红线话题。

- 格式规范：[`skills/api2human-candidate-card/references/a2hcard-spec.md`](skills/api2human-candidate-card/references/a2hcard-spec.md)
- 空白模板：[`assets/template.a2hcard`](skills/api2human-candidate-card/assets/template.a2hcard)
- 虚构示例：[`assets/example-zhangsan.a2hcard`](skills/api2human-candidate-card/assets/example-zhangsan.a2hcard)
- 导入：菜单栏 →「面试资料」→「从文件导入…」，或直接双击 `.a2hcard` 文件

两条核心规则：

1. 带 `[待确认]` / `[待补充]` 的**分句**，面试 AI 看不到（被整句删除），所以要把事实和不确定的内容拆成不同分句。
2. HTML 注释 `<!-- … -->` 也不会发给 AI，可用来记录分档依据等备注。

### 用 AI 把你的材料整理成角色卡

仓库自带一个 skill（`skills/api2human-candidate-card/`），内含完整的整理流程：读材料 → 提取事实 → 起草 → 最多 8 个补充问题 → 校验 → 交付。它的原则是**不编造、推断要标记、区分"我"和"团队"、技能宁低勿高**。

> 🔒 角色卡含个人信息。建议用本地运行的 agent 工作，只写到本地目录，不要提交到公开仓库（`.gitignore` 已屏蔽 `*.a2hcard`）。

#### 方式 A：Claude Code

```bash
# 安装 skill（个人级；也可放到项目的 .claude/skills/ 下）
mkdir -p ~/.claude/skills
cp -R skills/api2human-candidate-card ~/.claude/skills/
```

在放有简历 PDF/Word、项目文档的目录里启动 `claude`，然后说：

```text
把 ./resume.pdf 和 ./projects.md 整理成我的 API2Human 角色卡，目标岗位 JD 在 ./jd.txt
```

提到"角色卡""a2hcard""整理成角色卡"等词会自动触发。也可以显式指定：`使用 api2human-candidate-card skill ……`。

#### 方式 B：Codex（OpenAI Codex CLI）

若你的 Codex 版本支持 skills，可复制到它的 skills 目录（常见为 `~/.codex/skills/`，以你所用版本的文档为准）。不确定时，用通用写法最稳：在材料目录里启动 `codex`，说：

```text
请先完整阅读 <仓库路径>/skills/api2human-candidate-card/SKILL.md 和
references/a2hcard-spec.md，严格按其中流程，把 ./resume.pdf 整理成
./张三.a2hcard。完成后运行 validate_a2hcard.py 校验并修复所有 ❌。
```

也可以把这段话写进项目的 `AGENTS.md`，以后只需说"更新我的角色卡"。

#### 方式 C：DeepSeek 等其他模型（Harness / 任意 agent 框架）

DeepSeek 等模型本身没有 skill 机制，但只要所在 harness 能**读文件 + 执行 shell**（例如把 DeepSeek 接到 Claude Code、Codex、Aider、OpenCode 等 agent 框架里，或你自己写的 tool-use 循环），做法与方式 B 相同：把 `SKILL.md` 和 `a2hcard-spec.md` 作为指令喂给模型，让它按流程执行。要点：

- 先把 PDF/Word 转成文本再交给模型：`swift skills/api2human-candidate-card/scripts/pdf2txt.swift x.pdf`（macOS 自带 PDFKit），或 `pdftotext -layout x.pdf -`；Word 用 `textutil -convert txt -stdout x.docx`。
- 模型容易"润色拔高"，务必保留 `SKILL.md` 里的"不可违反的原则"，并最后跑校验脚本。
- 没有 agent 能力、只有聊天窗口时：把 `SKILL.md`、`a2hcard-spec.md`、`template.a2hcard` 和你的材料一起贴进去，让它输出完整 `.a2hcard`，自己保存为文件后再校验。

> DeepSeek 若要作为面试时的**回答模型**，在 `llm.json` 里把 `baseURL` / `authToken` / `model` 指向其 Anthropic 兼容端点即可（见上文）。这与"用 AI 整理角色卡"是两回事，可以用不同的模型。

#### 校验（任何方式都要做）

```bash
python3 skills/api2human-candidate-card/scripts/validate_a2hcard.py 张三.a2hcard            # ❌ 必须修，⚠️ 逐条判断
python3 skills/api2human-candidate-card/scripts/validate_a2hcard.py 张三.a2hcard --ai-view  # 预览面试 AI 实际能看到什么
```

重点检查：关键事实（尤其是"我的角色"）有没有因为和 `[待确认]` 写在同一分句而被删掉；有没有留下"分片键、"这样的残句。

## 隐私

- 录音在 `~/Library/Application Support/API2Human/Recordings`，面试资料在 `context.json`，密钥在 `llm.json`，均在仓库之外。
- `.gitignore` 已屏蔽 wav 等音频、`llm.json`、`.env`、个人 `.a2hcard`（仅放行测试 fixture 和虚构示例）。
- 推送前建议自查：`git ls-files | grep -iE '\.(wav|m4a|mp3|a2hcard)$|llm\.json|\.env'`

## 目录结构

```
Sources/API2Human   应用源码（Audio / STT / LLM / Screen / Views / Windows）
Tests/              单元测试与 fixture
scripts/            fetch-models.sh（下载依赖）、bundle.sh（打包 .app）
skills/             角色卡生成 skill（格式规范、模板、校验脚本）
Vendor/sherpa-onnx  头文件与 modulemap（动态库运行时下载）
```

## 许可证

采用 [Stellarloom Opened Sourced License](LICENSE)：可自由使用、复制、修改、分发，但**禁止商业用途**，且必须保留作者署名与版权声明。软件按"现状"提供，不含任何担保；违法使用的责任由使用者自行承担。

## 第三方

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)（Apache-2.0）：仅引用头文件，库与模型由 `fetch-models.sh` 下载，请遵守其各自许可。
