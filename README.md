# Siri+

[![Support on Boosty](https://img.shields.io/badge/Boosty-support-F15F2C?logo=boosty&logoColor=white)](https://boosty.to/rtm00)
[![Latest release](https://img.shields.io/github/v/release/rtmo0/siri-plus)](https://github.com/rtmo0/siri-plus/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)

A personal assistant for macOS 26 that lives in the menu bar. During a call in Zoom, Teams, Telegram, a browser or any other app, it listens, recognizes speech right on your Mac and suggests what to say about the topic being discussed. Outside calls, ⌃⌥Space opens a Siri-style panel: ask by voice or text, attach a file, get an answer.

The interface is in English and Russian and follows the system language. Swift 6, SwiftUI, Liquid Glass, no third-party dependencies.

## How it works

![How Siri+ works: call audio, microphone, voice and files are processed on the Mac; only text goes to the model (Claude, ChatGPT, DeepSeek or a server of your own), which returns hints, answers and meeting summaries](docs/how-it-works.svg)

## What it can do

| | Feature | Runs |
| :-: | --- | --- |
| ✅ | Lives in the menu bar, no Dock icon | Mac |
| ✅ | Listens to any call: Zoom, Teams, FaceTime, Telegram, Telemost, Slack, Discord, a browser, or all system audio | Mac |
| ✅ | Keeps “Me” (microphone) and “Them” (call audio) apart in the transcript | Mac |
| ✅ | On-device speech recognition in English, Russian and other macOS languages, with automatic language choice | Mac |
| ✅ | Spots questions in the conversation and suggests answers in a side panel | Mac + model |
| ✅ | A separate, faster model for hints, if you like: chats and summaries keep the main one | model |
| ✅ | Hint panel hidden from screen sharing | Mac |
| ✅ | Offers to start listening when a call begins and to stop when it ends | Mac |
| ✅ | Vocabularies: built-in IT and business glossaries, your own terms and imported files teach recognition the meeting's words, and the model fixes the misheard ones | Mac + model |
| ✅ | Meeting materials (agenda, names, terms) help recognition and hints; add documents, pictures, audio or video and their text is read on the Mac | Mac + model |
| ✅ | Meeting history: title, summary, action items with checkboxes, participants, the hints shown, full transcript | Mac + model |
| ✅ | Optional call recording to M4A, played back in the history | Mac |
| ✅ | Ask questions about a past meeting, export it to Markdown, send its summary by Mail, to Notes, Messages or Telegram | Mac + model |
| ✅ | Siri-style ask panel on ⌃⌥Space with voice dictation | Mac + model |
| ✅ | Chat with saved history and search | Mac + model |
| ✅ | Export chats, meetings or the whole history to Markdown | Mac |
| ✅ | Attach images, PDFs, text and code files; paste pictures and copied files with ⌘V | Mac + model |
| ✅ | Transcribe audio and video files (MP3, M4A, WAV, AIFF, MP4, MOV…) | Mac |
| ✅ | Claude: browser sign-in through Claude Code, or an API key | model |
| ✅ | Every model your account offers, with its own effort levels | model |
| ✅ | ChatGPT: browser sign-in to your account, or an API key | model |
| ✅ | DeepSeek: an API key, checked before it is saved, with the account balance | model |
| ✅ | Any OpenAI-compatible server: Ollama, LM Studio, OpenRouter, Groq… Local models keep everything on the Mac | Mac or model |
| ✅ | Subscription limits: how much is left and when it resets | Mac |
| ✅ | API key statistics: requests, tokens and an estimated cost for today, 7 and 30 days | Mac |
| ✅ | Desktop widget and a Shortcuts action | Mac |
| ✅ | Updates itself from GitHub releases | Mac |

## Install

Download `SiriPlus-<version>-arm64.dmg` from [Releases](https://github.com/rtmo0/siri-plus/releases) (Apple silicon, macOS 26 or later).

Siri+ is not signed with an Apple Developer ID, so macOS blocks the downloaded copy. Either:

- open the disk image, right-click `Install Siri+.command` → Open → Open. It copies the app to Applications and removes the quarantine flag;
- or drag `SiriPlus.app` to Applications and run:

```sh
xattr -dr com.apple.quarantine /Applications/SiriPlus.app
```

First launch:

1. The ✦ icon appears in the menu bar.
2. Settings → Models: Claude Opus through a Claude subscription is already there; sign in, or add other models (ChatGPT, an API key, DeepSeek, a local server) and choose what each one does.
3. Meeting → Start. macOS asks for screen and system audio recording and for the microphone.

## Meetings

- **Audio source.** A running call app is picked automatically. You can choose any other running app (for example a browser with Google Meet) or “All system audio”, which works with any call. With Safari, the call audio comes from WebKit's “Safari Graphics and Media” process, which is captured along with Safari. When you have talked for half a minute and nothing came from the call, the meeting screen says so: the source is probably wrong.
- **Your voice** comes from the microphone as a separate channel. Headphones are the most reliable. When the call plays through speakers (built-in, a display or AirPlay), the meeting screen says so, the microphone is not transcribed while the other side speaks unless you are clearly louder than their echo, and “Me” lines that nearly repeat them from the last 10 seconds are dropped. Words said over the other side may be lost then.
- **Language.** “System” listens for your system languages and keyboard layouts at once. For each speaker, the language whose recognizer is clearly more confident over the first phrases is kept and the others stop. You can also fix the language in Settings.
- **Materials.** The notes field next to the hints takes the agenda, facts and names. Drop files on it, paste them with ⌘V or use the paperclip: PDF, text and code are read, pictures and screenshots go through on-device text recognition, audio and video through on-device speech recognition, and the text is added to the notes (up to 40,000 characters per file).
- **Vocabulary.** On-device recognition mishears technical words (“губерни” for Kubernetes, “горбач коллектор” for garbage collector, “наряд ныть” for React Native). Settings → Vocabulary turns on the built-in glossaries (IT and development, Business and product), takes your own terms and imports text or CSV files. Recognition is given up to 150 of these terms (names and terms from the meeting notes first), and hints and summaries get the full list with known mishearings, so the model writes the terms correctly. A glossary file has one term per line; `Kubernetes | кубер, губерни` also says how a term may be misheard, and `# title: …` / `# title.ru: …` name it. Imported files live in `~/Library/Application Support/SiriPlus/Glossaries/`, where you can add and edit them in Finder.
- **Hints** come after a question from the other side and about every 45 seconds while the conversation moves on, only on questions, or only on request (the Hint button or ⌃⌥Space). The model answers “—” when no hint is needed, and nothing is shown. With “Hints on my questions too”, questions you ask aloud get hints as well: for practice, or a meeting you lead. The hints shown stay with the meeting in the history and in its Markdown.
- **Questions** are spotted locally by question words after a short pause, since on-device Russian recognition adds no punctuation.
- **History.** After Stop, the meeting is saved on your Mac with a title, summary, action items and participants written by the model. Rename a meeting at the top of its page or with “Rename…” in the list; chats are renamed the same way. The search covers everything, including the transcript. “Ask about meeting” opens a chat that answers from the transcript.
- **Recording.** Off by default. With “Save meeting audio (M4A)” on, the call and your microphone are saved as one M4A file with the meeting (about 30–60 MB an hour) and play back in the history. The file is deleted with the meeting.
- **Sending the summary.** The share button in a meeting's toolbar sends its title, participants, summary and tasks by Mail, to Notes, Messages, Telegram or any app in the macOS share menu.
- **Export.** A meeting or a chat saves as a Markdown file from its toolbar. Settings → Conversation → Export saves the whole history into a folder: `Meetings/` and `Chats/` with one file each (a recorded meeting's M4A next to its Markdown), and `index.md` linking them with dates and the first line of each summary.

Tell participants you use an assistant: recording a conversation without consent is illegal in many countries.

## Chat and the ask panel

- **⌃⌥Space** in any app opens a translucent panel that starts listening right away. Speak a command; it is sent when you fall silent for 1.5 seconds. Press again to send at once.
- The panel sits in the top-right corner with the same margin as widgets. Drag it by any empty area; the place is remembered.
- Attach files with the paperclip, drag and drop, or ⌘V: a copied screenshot or picture is attached as an image, files copied in Finder as files; text pastes as usual. Images go to the model as images; PDF, text and code are read on the Mac; audio and video are transcribed on the Mac and only the transcript is sent. Telegram voice notes (OGG/Opus) need converting first.
- The input grows up to 13 lines, then scrolls. Return sends, Shift-Return adds a line.

## Models and sign-in

Settings has four pages: **Models**, **Meetings**, **Vocabulary** and **General**.

On **Models**, add each model you use with “Add Model…”: the provider, the sign-in (subscription or API key), the model, its effort and, if you like, a name. A provider that is not connected yet is signed in or given its key right in that window. The list shows each model, whether it is ready and what it does.

**Use For** routes the work: one model for the chat and the ask panel, one for meeting hints, one for meeting summaries — the same model or three different ones. Hints have to arrive within seconds, so a fast model with little thinking suits them, for example DeepSeek Flash without thinking or Claude Haiku. A routed model's effort is sent as is, “no thinking” included; “Automatic” keeps hints brief and thinks longer on detailed answers. Settings warns when a routed model is not connected or thinks too long for hints.

Each model in the list shows whether it is ready and, under it, what its sign-in or key has left or used: subscription limits, DeepSeek's balance, today's requests and cost. Its window signs in or out, takes or deletes the key and unfolds the full limits or statistics; models of one provider share the sign-in or key. Settings from Siri+ 0.5.2 and earlier become models on first launch: the provider in use, plus the separate hint model if there was one.

| Provider | Browser sign-in (default) | API key |
| --- | --- | --- |
| **Claude** | Through the official [Claude Code](https://code.claude.com/docs/en/setup): “Sign in to Claude” opens Terminal with `claude auth login`. Requests run through `claude -p` in safe mode (no tools, no saved sessions) and use your Pro/Max limits. | A key from [Claude Console](https://platform.claude.com/settings/keys); direct streaming requests to `api.anthropic.com`. |
| **ChatGPT** | OAuth sign-in to your ChatGPT account (PKCE, loopback on port 1455/1457), as in Codex. Tokens live in the Keychain and refresh automatically. | An OpenAI API key, Responses API. |
| **DeepSeek** | — | A key from [DeepSeek Platform](https://platform.deepseek.com/api_keys); streaming Chat Completions at `api.deepseek.com` (DeepSeek Flash, V4 Pro and whatever the key lists). |
| **Other** | — | Any server with an OpenAI-compatible Chat Completions API, with an optional key. Presets for Ollama (`http://localhost:11434/v1`), LM Studio (`http://localhost:1234/v1`), OpenRouter and Groq; the model list comes from the server's `GET /models`. |

Every API key is checked with its provider before it is saved: a key the provider refuses is not saved, and a key that could not be checked (no connection) is saved and checked again later. A server of the “Other” provider is checked the same way: it has to answer and list its models.

With a local server such as Ollama or LM Studio, nothing at all leaves the Mac. Such servers take no effort setting and decide the answer length themselves.

The model list comes from your account: with a Claude sign-in, every model Claude Code offers you (Opus, Sonnet, Haiku, Fable and pinned older versions); with an API key, the models the key can use; with ChatGPT, the models your account lists. Haiku is the fastest for meeting hints (the answer starts in about two seconds).

**Effort** sets how long the model thinks before answering, from low to maximum. Settings shows only the levels the chosen model accepts. “Automatic” thinks briefly for brief answers and longer for detailed ones. Meeting hints always think briefly so they arrive in seconds.



With an account sign-in, Siri+ shows what is left of your subscription limits and when they reset: in Settings → Models. Claude limits come from `claude -p /usage`, ChatGPT limits from the account's usage endpoint.

API keys have no subscription limits; they are billed per token. For a Claude, OpenAI or DeepSeek key and for an “Other” server, a model's window in Settings → Models shows what requests from this Mac used today, in 7 and in 30 days: requests, input and output tokens and, for Claude and DeepSeek, an estimated cost at list prices (DeepSeek's off-peak hours at half price). The counts come from the token usage each reply reports and stay in `~/Library/Application Support/SiriPlus/Usage/`. With DeepSeek, the account balance (from `GET /user/balance`) is shown too.

Subscription sign-in is for personal use on your own Mac.

## Privacy

| On your Mac | In the cloud (the chosen provider; nothing with a local server) |
| --- | --- |
| Capturing call and microphone audio | Meeting hints |
| Speech recognition | Answers in chat and the ask panel |
| Spotting questions | Reading an attached screenshot or image |
| Reading files added to the meeting materials, text on pictures included | |
| Sign-in tokens and API keys (Keychain) | Meeting title, participants and summary after Stop |
| Chats and meeting history (`~/Library/Application Support/SiriPlus/`) | |
| Meeting audio, if you turn recording on (`Recordings/` in the same folder) | |

Audio is never sent anywhere, recorded or not. The model receives your messages, attachments, and a recent piece of the transcript (up to about 6,000 characters) with the meeting materials when a hint is needed. After Stop, the transcript is sent once more to write the summary.

## Updates

Siri+ checks the [latest release](https://github.com/rtmo0/siri-plus/releases/latest) 10 seconds after launch and every 12 hours, or on demand from the menu (where “About Siri+” shows the version and license). When a new version is out, it offers to install it: downloads the DMG with a progress bar, verifies its SHA-256, checks the version inside, replaces the app and relaunches. The app needs to live in a folder you can write to, such as Applications.

## Build from source

Requires Xcode 26 and macOS 26.

```sh
bash scripts/build.sh
open build/Build/Products/Debug/SiriPlus.app
```

macOS remembers microphone and screen recording permissions by the app's signature. An ad-hoc signature changes with every build, so permissions would reset each time. Create a stable self-signed certificate once and every build is signed with it:

```sh
bash scripts/make-signing-identity.sh
```

For GitHub releases, add the repository secrets `SIRIPLUS_SIGNING_P12` (the base64 printed by the script) and `SIRIPLUS_SIGNING_P12_PASSWORD`.

Tests and project generation:

```sh
swift test                               # shared logic, no screen, microphone or network access
python3 scripts/generate-project.py      # after adding Swift files
```

Releases: pushing a tag like `v0.5.0` builds the DMG on the `macos-26` runner and publishes a GitHub Release. `bash scripts/release.sh 0.5.0` builds the same DMG locally into `dist/`.

### Project layout

```text
SiriPlus/
  App/          App, AppModel (chat, attachments, dictation, keys), MeetingModel (meeting, hints,
                materials), histories, updates, subscription limits and API key usage
  Features/     Windows: chat, meeting, settings, ask panel, update prompt
  Models/       Messages, settings, transcript and question detector
  Services/     Model providers (Claude, OpenAI, DeepSeek, OpenAI-compatible servers), usage ledgers,
                audio capture and speech recognition, media transcription, text recognition for
                materials, Keychain, screenshots, hotkey, updater
  Intents/      Siri and Shortcuts action
  Resources/    Info.plist, entitlements, string catalogs (en, ru), icons
SiriPlusWidget/ Desktop widget
Tests/          Unit tests
```

UI strings are written in English in code; the Russian translation lives in `Resources/Localizable.xcstrings`.

## Support

Siri+ is free and open source. If it saves you time on calls, you can support development on [Boosty](https://boosty.to/rtm00). Bug reports and pull requests help a lot too.
