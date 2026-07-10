# Voice Teleprompter 语音提词器

An open-source Android teleprompter app with **voice-following subtitles** — the script scrolls automatically as you speak, powered by offline speech recognition (Vosk). Built with Flutter.

一款开源的安卓提词器 App,核心功能是**语音跟随字幕**——你念稿子,字幕跟着你的语速自动滚动。基于离线语音识别(Vosk),用 Flutter 开发。

> Built by a food-delivery rider in Shanghai learning to make content. This is my first original open-source project.
> 上海一名外卖骑手在学做内容的过程中做的,这是我第一个原创开源项目。

## ✨ Features 功能

- 🎤 **Voice-following mode** — subtitles auto-scroll as you speak (Chinese & English)
- ⏱️ **Constant-speed mode** — traditional teleprompter with adjustable speed + live preview
- 🎥 **Camera overlay** — front camera full-screen with a draggable, resizable prompt window
- 🎬 **Multi-segment recording** — record clips, manage thumbnails, merge into one video (FFmpeg)
- 🎨 Customizable — font size, colors, opacity, line spacing, mirror mode
- 📴 **Fully offline** — no network, no account, no data leaves your phone

## 📸 Screenshots 截图

<!-- 待补充:把几张手机截图拖进来 -->
<!-- TODO: add screenshots here -->

## 🚀 Build 编译

### 1. Clone

```bash
git clone https://github.com/SaiTaoTechnology/voice-teleprompter.git
cd voice-teleprompter
```

### 2. Download speech models 下载语音模型

Models are not included in this repo due to size. Download from [alphacephei.com/vosk/models](https://alphacephei.com/vosk/models) and place the **zip files** (do not unzip) into `assets/models/`:

模型因体积原因未包含在仓库里。从上面链接下载后,把 **zip 文件**(不要解压)放进 `assets/models/`:

- English: `vosk-model-small-en-us-0.15.zip`
- Chinese: `vosk-model-small-cn-0.22.zip` → rename to / 重命名为 `vosk-model-small-cn.zip`

### 3. Run

```bash
flutter pub get
flutter run
```

## 🛠️ Tech Notes 技术说明

This project uses two plugins that needed patching to build with modern Android Gradle Plugin (AGP 9). The patched versions are vendored under `third_party/` and wired via `dependency_overrides` in `pubspec.yaml`, so the build works out of the box:

本项目用到的两个插件在新版 AGP 9 下无法直接编译,已打补丁并放在 `third_party/` 下,通过 `pubspec.yaml` 的 `dependency_overrides` 引用,所以 clone 下来即可编译:

- **vosk_flutter** — added `namespace`, bumped `compileSdk` to 34, updated AGP classpath
- **permission_handler_android** — removed deprecated v1 embedding (`Registrar`) references, bumped `compileSdk`

## 📄 License 许可

MIT

## 🙏 Credits 致谢

- [Vosk](https://alphacephei.com/vosk/) — offline speech recognition
- [FFmpeg Kit](https://github.com/arthenica/ffmpeg-kit) — video processing
- Built with [Flutter](https://flutter.dev)