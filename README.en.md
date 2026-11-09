# API2Human

[中文](README.md) | **English**

A macOS menu-bar real-time prompter: capture system audio (the other party's voice) → local streaming speech recognition → call an LLM together with your **Candidate Card** → show a ready-to-say answer in a floating panel. It also supports lasso-select OCR for on-screen code questions and local project code search.

> ⚠️ **Compliance notice**: many employers explicitly forbid AI assistance during interviews. Use this project for mock interviews, practice and review, or where it is allowed, and take responsibility for how you use it.

## Features

- **Listen**: captures system audio via Core Audio Process Tap; optionally records the microphone for later review
- **Recognize**: local [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) streaming zh/en model — offline, with hotword support
- **Answer**: question + resume/JD/card → streamed LLM answer (conclusion first, then 2–4 points, ~200 chars); tolerant of ASR typos
- **No fabrication**: experiences, numbers or salary not in your materials are never invented; the answer flags "⚠️ not in your materials" and offers an honest line instead
- **Lasso & search**: select code or a question on screen → OCR → line-by-line reasoning, "issues found" and "role in the project", grounded by searching your local project directories for real call chains
- **Read aloud**: system TTS (the app's own audio is excluded from capture to avoid feedback)
- **Review**: each session saves `system.wav` / `mic.wav` / `transcript.txt` (outside this repo)

## Requirements

macOS 14.2+ (Core Audio Process Tap), Apple Silicon, Swift 6 toolchain

## Build & run

```bash
scripts/fetch-models.sh      # download sherpa-onnx libs and the zh/en streaming model (not in git)
scripts/bundle.sh release    # produces build/API2Human.app
open build/API2Human.app
swift test                   # unit tests (run fetch-models.sh first)
```

On first launch grant Screen Recording, Microphone and System Audio Recording permissions. `bundle.sh` prefers a local self-signed certificate named `API2Human Local Signing` so permissions survive re-bundling; without it, it falls back to ad-hoc signing (you must re-authorize after every build).

## LLM configuration (no secrets in the repo)

Create `~/Library/Application Support/API2Human/llm.json`:

```json
{
  "baseURL": "https://api.anthropic.com",
  "authToken": "your API key here",
  "model": "your model name",
  "maxTokens": 800
}
```

Or use environment variables: `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` (or `ANTHROPIC_API_KEY`) / `API2HUMAN_MODEL`.

The client speaks the Anthropic Messages protocol and sends both `x-api-key` and `Authorization: Bearer`, so it works with Anthropic-compatible gateways; a fallback endpoint can be configured. Whether a third-party model offers an Anthropic-compatible endpoint is up to its official docs.

## Candidate Card (`.a2hcard`)

A card answers one question: **"What can I truthfully say about myself in an interview?"** It is a UTF-8 Markdown file that turns your resume, projects and notes into quotable facts, with explicit skill boundaries (proficient / used / only heard of or never used) and red-line topics. (The card content itself is written in Chinese by default; the format also supports `language: en`.)

- Format spec: [`skills/api2human-candidate-card/references/a2hcard-spec.md`](skills/api2human-candidate-card/references/a2hcard-spec.md)
- Blank template: [`assets/template.a2hcard`](skills/api2human-candidate-card/assets/template.a2hcard)
- Fictional example: [`assets/example-zhangsan.a2hcard`](skills/api2human-candidate-card/assets/example-zhangsan.a2hcard)
- Import: menu bar → "面试资料" (Interview Materials) → "从文件导入…" (Import from file…), or double-click an `.a2hcard` file

Two core rules:

1. Any **clause** carrying `[待确认]` (to confirm) / `[待补充]` (to fill in) is removed before the text reaches the AI — so keep facts and uncertain parts in separate clauses.
2. HTML comments `<!-- … -->` are never sent to the AI; use them for notes such as the rationale for a skill level.

### Generate a card from your materials with AI

The repo ships a skill (`skills/api2human-candidate-card/`) with the complete workflow: read materials → extract facts → draft → ask at most 8 follow-up questions → validate → deliver. Its principles: **never fabricate, mark inferences, separate "me" from "the team", rate skills conservatively**.

> 🔒 Cards contain personal data. Use a locally running agent, write only to local directories, and never commit cards to a public repo (`*.a2hcard` is git-ignored).

#### Option A: Claude Code

```bash
# install the skill (user-level; or put it under the project's .claude/skills/)
mkdir -p ~/.claude/skills
cp -R skills/api2human-candidate-card ~/.claude/skills/
```

Start `claude` in a folder containing your resume PDF/Word and project docs, then say:

```text
Turn ./resume.pdf and ./projects.md into my API2Human candidate card. The target JD is in ./jd.txt
```

Mentioning "candidate card" / "a2hcard" triggers the skill automatically; you can also name it explicitly: `Use the api2human-candidate-card skill to …`.

#### Option B: Codex (OpenAI Codex CLI)

If your Codex version supports skills, copy the folder to its skills directory (commonly `~/.codex/skills/` — check the docs of your version). When unsure, the generic approach is the most robust: start `codex` in the materials folder and say:

```text
First read <repo path>/skills/api2human-candidate-card/SKILL.md and
references/a2hcard-spec.md in full, follow that workflow strictly, and turn
./resume.pdf into ./my-name.a2hcard. Then run validate_a2hcard.py and fix every ❌.
```

You can also put that instruction in the project's `AGENTS.md` so that "update my card" is enough next time.

#### Option C: DeepSeek and other models (harness / any agent framework)

Models such as DeepSeek have no built-in skill mechanism, but as long as the harness around them can **read files and run shell commands** (e.g. DeepSeek plugged into Claude Code, Codex, Aider, OpenCode or your own tool-use loop), the procedure is the same as Option B: feed `SKILL.md` and `a2hcard-spec.md` to the model as instructions and let it follow the workflow. Tips:

- Convert PDF/Word to text first: `swift skills/api2human-candidate-card/scripts/pdf2txt.swift x.pdf` (uses macOS PDFKit) or `pdftotext -layout x.pdf -`; for Word use `textutil -convert txt -stdout x.docx`.
- Models like to "polish and inflate". Keep the "inviolable principles" of `SKILL.md` in the prompt and always run the validator at the end.
- With only a chat window (no agent): paste `SKILL.md`, `a2hcard-spec.md`, `template.a2hcard` and your materials, ask for the full `.a2hcard`, save it yourself, then validate.

> Using DeepSeek as the **answering model** during an interview is a separate matter: point `baseURL` / `authToken` / `model` in `llm.json` at its Anthropic-compatible endpoint (see above). You may use different models for card generation and live answering.

#### Validate (always)

```bash
python3 skills/api2human-candidate-card/scripts/validate_a2hcard.py me.a2hcard            # ❌ must fix, ⚠️ judge each
python3 skills/api2human-candidate-card/scripts/validate_a2hcard.py me.a2hcard --ai-view  # preview what the interview AI actually sees
```

Check especially that key facts (above all "my role") were not dropped because they share a clause with `[待确认]`, and that no dangling fragments such as "shard key," remain.

## Privacy

- Recordings live in `~/Library/Application Support/API2Human/Recordings`, interview materials in `context.json`, secrets in `llm.json` — all outside the repo.
- `.gitignore` blocks audio files, `llm.json`, `.env` and personal `.a2hcard` files (only test fixtures and the fictional example are allowed).
- Self-check before pushing: `git ls-files | grep -iE '\.(wav|m4a|mp3|a2hcard)$|llm\.json|\.env'`

## Layout

```
Sources/API2Human   app source (Audio / STT / LLM / Screen / Views / Windows)
Tests/              unit tests and fixtures
scripts/            fetch-models.sh (download deps), bundle.sh (build .app)
skills/             card-generation skill (spec, template, validator)
Vendor/sherpa-onnx  headers and modulemap (dylibs are downloaded at setup)
```

## Third party

- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0): only headers are referenced; libraries and models are downloaded by `fetch-models.sh` — please respect their licenses.
