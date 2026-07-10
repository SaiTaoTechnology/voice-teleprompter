import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'vosk_service.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const TeleprompterApp());
}

class TeleprompterApp extends StatelessWidget {
  const TeleprompterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Teleprompter',
      theme: ThemeData.dark(),
      home: const TeleprompterScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// 录制的片段
class VideoSegment {
  final String path;
  final int seconds;
  final Uint8List? thumb;
  VideoSegment(this.path, this.seconds, this.thumb);
}

class TeleprompterScreen extends StatefulWidget {
  const TeleprompterScreen({super.key});

  @override
  State<TeleprompterScreen> createState() => _TeleprompterScreenState();
}

class _TeleprompterScreenState extends State<TeleprompterScreen> {
  CameraController? _cam;
  bool _camReady = false;
  bool _isRecording = false;
  int _recSecs = 0;
  Timer? _recTimer;
  bool _merging = false;

  // 多段录制
  final List<VideoSegment> _segments = [];

  // 稿子
  String _scriptTitle = '';
  String _scriptText = '';

  final ScrollController _scroll = ScrollController();
  Timer? _scrollTimer;
  bool _isPlaying = false;
  // bool _previewing = false;
  // double _previewFromOffset = 0;
  bool _showSettings = false;
  bool _isMirrored = false;

  // 悬浮窗状态
  double _boxX = 16;
  double _boxY = 90;
  double _boxW = 340;
  double _boxH = 260;

  // 设置
  double _speed = 1.0;
  double _fontSize = 24;
  Color _textColor = Colors.white;
  final Color _bgColor = Colors.black;
  double _bgOpacity = 0.55;
  double _lineHeight = 1.5;
  double _hPad = 12;
  int _delaySecs = 3;

  // 语音跟随
  final VoskService _voskService = VoskService();
  bool _voiceMode = false; // false=匀速 true=AI语速
  VoskLang _selLang = VoskLang.english;
  int _lastMatchIdx = 0;

  final List<Color> _textColors = [
    Colors.white, Colors.orangeAccent, Colors.yellow, Colors.lightGreenAccent,
    Colors.greenAccent, Colors.cyanAccent, Colors.lightBlueAccent,
    Colors.pinkAccent, Colors.redAccent,
  ];

  @override
  void initState() {
    super.initState();
    _initCam();
    _voskService.addListener(() {
      if (!mounted) return;
      final text = _voskService.partial.isNotEmpty
          ? _voskService.partial
          : _voskService.lastResult;
      if (text.isNotEmpty && _voiceMode && _isRecording) {
        _scrollToRecognized(text);
      }
      setState(() {});
    });
  }

  Future<void> _initCam() async {
    if (cameras.isEmpty) return;
    CameraDescription? front;
    for (var c in cameras) {
      if (c.lensDirection == CameraLensDirection.front) { front = c; break; }
    }
    final cam = front ?? cameras[0];
    _cam = CameraController(cam, ResolutionPreset.high, enableAudio: true);
    await _cam!.initialize();
    if (mounted) setState(() => _camReady = true);
  }

  // 根据稿子内容自动判断语言
  VoskLang _detectLang() {
    if (_scriptText.isEmpty) return VoskLang.english;
    int cn = 0;
    int total = 0;
    for (final rune in _scriptText.runes) {
      if (rune > 0x20) total++;
      if (rune >= 0x4E00 && rune <= 0x9FFF) cn++;
    }
    if (total == 0) return VoskLang.english;
    return (cn / total > 0.3) ? VoskLang.chinese : VoskLang.english;
  }

  // ====== 录像:总开关 ======
  Future<void> _toggleRec() async {
    if (_cam == null || !_camReady || _merging) return;

    if (_isRecording) {
      _pauseScroll();
      if (_voiceMode) await _voskService.stop();

      _recTimer?.cancel();
      final file = await _cam!.stopVideoRecording();
      final secs = _recSecs;
      Uint8List? thumb;
      try {
        final dir = await getTemporaryDirectory();
        final thumbPath =
            '${dir.path}/thumb_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final session = await FFmpegKit.execute(
          "-i '${file.path}' -ss 00:00:00.5 -vframes 1 -vf scale=120:-1 '$thumbPath'",
        );
        final rc = await session.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          final f = File(thumbPath);
          if (await f.exists()) thumb = await f.readAsBytes();
        }
      } catch (_) {}
      setState(() {
        _isRecording = false;
        _recSecs = 0;
        _segments.add(VideoSegment(file.path, secs, thumb));
      });
    } else {
      if (_scriptText.trim().isEmpty) {
        _editScript();
        return;
      }

      if (_voiceMode) {
        if (!_voskService.ready || _voskService.lang != _selLang) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('正在加载语音模型...'),
              duration: Duration(seconds: 8)));
          await _voskService.init(_selLang);
          if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
          if (!_voskService.ready && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('❌ 语音模型加载失败,本次用匀速滚动')));
            setState(() => _voiceMode = false);
          }
        }
      }

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => CountdownDialog(
          seconds: _delaySecs,
          onComplete: () async {
            Navigator.pop(context);
            await _cam!.startVideoRecording();
            setState(() => _isRecording = true);
            _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
              setState(() => _recSecs++);
            });
            if (_voiceMode) {
              _lastMatchIdx = 0;
              await _voskService.start();
            } else {
              setState(() => _isPlaying = true);
              _startScroll();
            }
          },
        ),
      );
    }
  }

  // ====== 完成:拼接所有片段 ======
  Future<void> _finish() async {
    if (_segments.isEmpty || _merging) return;
    if (_isRecording) await _toggleRec();

    if (_segments.length == 1) {
      await Gal.putVideo(_segments.first.path, album: '提词器');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ 视频已保存到相册')));
        setState(() => _segments.clear());
      }
      return;
    }

    setState(() => _merging = true);
    try {
      final dir = await getTemporaryDirectory();
      final listFile = File('${dir.path}/concat_list.txt');
      final buffer = StringBuffer();
      for (var seg in _segments) {
        buffer.writeln("file '${seg.path}'");
      }
      await listFile.writeAsString(buffer.toString());

      final outPath =
          '${dir.path}/merged_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final cmd =
          "-f concat -safe 0 -i '${listFile.path}' -c copy '$outPath'";

      final session = await FFmpegKit.execute(cmd);
      final rc = await session.getReturnCode();

      if (ReturnCode.isSuccess(rc)) {
        await Gal.putVideo(outPath, album: '提词器');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ 已合并并保存到相册')));
          setState(() => _segments.clear());
        }
      } else {
        final cmd2 = _buildReencodeCmd(outPath);
        final s2 = await FFmpegKit.execute(cmd2);
        final rc2 = await s2.getReturnCode();
        if (ReturnCode.isSuccess(rc2)) {
          await Gal.putVideo(outPath, album: '提词器');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('✅ 已合并并保存到相册')));
            setState(() => _segments.clear());
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('❌ 合并失败,请重试')));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ 出错: $e')));
      }
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  String _buildReencodeCmd(String outPath) {
    final inputs = StringBuffer();
    final filter = StringBuffer();
    for (int i = 0; i < _segments.length; i++) {
      inputs.write("-i '${_segments[i].path}' ");
      filter.write('[$i:v][$i:a]');
    }
    filter.write('concat=n=${_segments.length}:v=1:a=1[outv][outa]');
    return "${inputs.toString()}-filter_complex \"${filter.toString()}\" "
        "-map \"[outv]\" -map \"[outa]\" '$outPath'";
  }

  void _deleteSegment(int i) {
    setState(() => _segments.removeAt(i));
  }

  String get _recTime {
    final m = _recSecs ~/ 60;
    final s = _recSecs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ====== 滚动 ======
  void _startScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_scroll.hasClients) {
        final max = _scroll.position.maxScrollExtent;
        final cur = _scroll.offset;
        if (cur >= max) {
          if (_showSettings && !_isRecording) {
            _scroll.jumpTo(0); // 预览时循环滚
          } else {
            _pauseScroll();
          }
        }
        else { _scroll.jumpTo(cur + _speed * 0.5); }
      }
    });
  }

  void _pauseScroll() {
    _scrollTimer?.cancel();
    setState(() => _isPlaying = false);
  }

  void _reset() {
    _pauseScroll();
    _lastMatchIdx = 0;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  // // 速度滑块实时预览
  // void _startPreview() {
  //   if (_isRecording || _voiceMode) return;
  //   _previewing = true;
  //   _previewFromOffset = _scroll.hasClients ? _scroll.offset : 0;
  //   _startScroll();
  // }

  // void _stopPreview() {
  //   if (!_previewing) return;
  //   _previewing = false;
  //   if (!_isRecording) {
  //     _pauseScroll();
  //     if (_scroll.hasClients) _scroll.jumpTo(_previewFromOffset);
  //   }
  // }

  // ====== 语音对齐滚动 ======
  void _scrollToRecognized(String recognized) {
    if (_scriptText.isEmpty || !_scroll.hasClients) return;
    final isCn = _selLang == VoskLang.chinese;

    if (isCn) {
      final script = _scriptText.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
      final clean = recognized.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), '');
      if (script.isEmpty || clean.isEmpty) return;
      final query =
          clean.length > 8 ? clean.substring(clean.length - 8) : clean;
      if (query.length < 2 || script.length < query.length) return;

      int best = -1;
      double bestScore = 0;
      final start =
          (_lastMatchIdx - 5).clamp(0, script.length - query.length);
      for (int i = start; i <= script.length - query.length; i++) {
        int hit = 0;
        for (int j = 0; j < query.length; j++) {
          if (script[i + j] == query[j]) hit++;
        }
        final score = hit / query.length;
        if (score > bestScore) {
          bestScore = score;
          best = i;
          if (score >= 0.99) break;
        }
      }
      if (best < 0 || bestScore < 0.5) return;
      _lastMatchIdx = best;
      _animateToRatio((best + query.length) / script.length);
    } else {
      final script =
          _scriptText.toLowerCase().replaceAll(RegExp(r'[^a-z\s]'), '');
      final words = recognized.toLowerCase().trim().split(RegExp(r'\s+'));
      final query = words.length > 3
          ? words.sublist(words.length - 3).join(' ')
          : words.join(' ');
      if (query.isEmpty) return;
      final searchFrom = (_lastMatchIdx - 20).clamp(0, script.length);
      final idx = script.indexOf(query, searchFrom);
      if (idx < 0) return;
      _lastMatchIdx = idx;
      _animateToRatio(idx / script.length);
    }
  }

  void _animateToRatio(double ratio) {
    final max = _scroll.position.maxScrollExtent;
    final target = (ratio * max).clamp(0.0, max);
    _scroll.animateTo(target,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  // ====== 编辑稿子(全屏页面) ======
  Future<void> _editScript() async {
    final result = await Navigator.push<Map<String, String>>(
      context,
      MaterialPageRoute(
        builder: (_) => EditScriptPage(
          initialTitle: _scriptTitle,
          initialText: _scriptText,
        ),
      ),
    );
    if (result != null) {
      setState(() {
        _scriptTitle = result['title'] ?? '';
        _scriptText = result['text'] ?? '';
        _selLang = _detectLang();
        _lastMatchIdx = 0;
      });
    }
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _recTimer?.cancel();
    _scroll.dispose();
    _cam?.dispose();
    _voskService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ① 全屏摄像头
          if (_camReady && _cam != null)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _cam!.value.previewSize!.height,
                  height: _cam!.value.previewSize!.width,
                  child: CameraPreview(_cam!),
                ),
              ),
            )
          else
            const ColoredBox(color: Colors.black),

          // ② 悬浮提词窗口
          Positioned(
            left: _boxX, top: _boxY,
            width: _boxW, height: _boxH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      if (!_isRecording) _editScript();
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        color: _bgColor.withOpacity(_bgOpacity),
                        padding: EdgeInsets.fromLTRB(
                            _hPad, 8, _hPad, 52),
                        child: Transform(
                          alignment: Alignment.center,
                          transform: _isMirrored
                              ? (Matrix4.identity()..scale(-1.0, 1.0, 1.0))
                              : Matrix4.identity(),
                          child: SingleChildScrollView(
                            controller: _scroll,
                            physics: _isRecording
                                ? const NeverScrollableScrollPhysics()
                                : const ClampingScrollPhysics(),
                            child: Text(
                              _scriptText.isEmpty
                                  ? '点击此处编辑提词稿'
                                  : _scriptText,
                              style: TextStyle(
                                color: _scriptText.isEmpty
                                    ? Colors.white54
                                    : _textColor,
                                fontSize: _fontSize,
                                fontWeight: FontWeight.bold,
                                height: _lineHeight,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 底部工具栏:拖动 | 设置 | 改稿 | A+ | A- | 缩放
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(16)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        GestureDetector(
                          onPanUpdate: (d) {
                            setState(() {
                              _boxX = (_boxX + d.delta.dx)
                                  .clamp(0.0, sw - _boxW);
                              _boxY = (_boxY + d.delta.dy)
                                  .clamp(0.0, sh - _boxH);
                            });
                          },
                          child: const Icon(Icons.open_with,
                              color: Colors.white70, size: 20),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() => _showSettings = !_showSettings);
                            if (_showSettings && !_voiceMode && !_isRecording) {
                              _startScroll(); // 打开面板即预览滚动
                            } else if (!_showSettings && !_isRecording) {
                              _pauseScroll();
                              if (_scroll.hasClients) _scroll.jumpTo(0);
                            }
                          },
                          child: Icon(Icons.settings,
                              color: _showSettings
                                  ? Colors.blueAccent
                                  : Colors.white70,
                              size: 20),
                        ),
                        GestureDetector(
                          onTap: () {
                            if (!_isRecording) _editScript();
                          },
                          child: const Icon(Icons.edit_note,
                              color: Colors.white70, size: 24),
                        ),
                        GestureDetector(
                          onTap: () => setState(() =>
                              _fontSize = (_fontSize + 2).clamp(16.0, 72.0)),
                          child: const Text('A+',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                        ),
                        GestureDetector(
                          onTap: () => setState(() =>
                              _fontSize = (_fontSize - 2).clamp(16.0, 72.0)),
                          child: const Text('A-',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold)),
                        ),
                        GestureDetector(
                          onPanUpdate: (d) {
                            setState(() {
                              _boxW = (_boxW + d.delta.dx)
                                  .clamp(200.0, sw - _boxX);
                              _boxH = (_boxH + d.delta.dy)
                                  .clamp(140.0, sh - _boxY);
                            });
                          },
                          child: const Icon(Icons.zoom_out_map,
                              color: Colors.white70, size: 20),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ③ 顶部状态栏
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              color: Colors.black38,
              padding: const EdgeInsets.fromLTRB(8, 40, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const SizedBox(width: 48),
                  if (_isRecording)
                    Row(children: [
                      const Icon(Icons.circle, color: Colors.red, size: 12),
                      const SizedBox(width: 6),
                      Text(_recTime,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    ])
                  else if (_segments.isNotEmpty)
                    Text('已录 ${_segments.length} 段',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 16))
                  else
                    const Text('提词器',
                        style:
                            TextStyle(color: Colors.white70, fontSize: 16)),
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),

          // ④ 音浪条(录制时显示)
          if (_isRecording)
            const Positioned(
              bottom: 150, left: 24, right: 24,
              child: _AudioWave(),
            ),

          // ⑤ 底部控制区
          if (!_showSettings)
            Positioned(
              bottom: 24, left: 0, right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_segments.isNotEmpty)
                    Container(
                      height: 66,
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _segments.length,
                        itemBuilder: (ctx, i) {
                          final seg = _segments[i];
                          return Container(
                            width: 56, height: 66,
                            margin: const EdgeInsets.only(right: 10),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  width: 50, height: 60,
                                  margin: const EdgeInsets.only(
                                      top: 6, right: 6),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(6),
                                    border:
                                        Border.all(color: Colors.white54),
                                    color: const Color(0xFF3A3A5A),
                                    image: seg.thumb != null
                                        ? DecorationImage(
                                            image: MemoryImage(seg.thumb!),
                                            fit: BoxFit.cover)
                                        : null,
                                  ),
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    width: double.infinity,
                                    color: Colors.black54,
                                    child: Text(
                                      '${seg.seconds}s',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 0, right: 0,
                                  child: GestureDetector(
                                    onTap: () => _deleteSegment(i),
                                    child: Container(
                                      width: 20, height: 20,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.red,
                                      ),
                                      child: const Icon(Icons.close,
                                          color: Colors.white, size: 14),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _toggleRec,
                        child: Container(
                          width: 72, height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border:
                                Border.all(color: Colors.white, width: 4),
                            color:
                                _isRecording ? Colors.red : Colors.black45,
                          ),
                          child: Icon(
                            _isRecording
                                ? Icons.stop
                                : Icons.fiber_manual_record,
                            color: _isRecording ? Colors.white : Colors.red,
                            size: 36,
                          ),
                        ),
                      ),
                      if (_segments.isNotEmpty && !_isRecording) ...[
                        const SizedBox(width: 24),
                        GestureDetector(
                          onTap: _merging ? null : _finish,
                          child: Container(
                            height: 56,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 28),
                            decoration: BoxDecoration(
                              color: _merging
                                  ? Colors.grey
                                  : const Color(0xFFFF9500),
                              borderRadius: BorderRadius.circular(28),
                            ),
                            alignment: Alignment.center,
                            child: _merging
                                ? const SizedBox(
                                    width: 24, height: 24,
                                    child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2))
                                : const Text('完成',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),

          // ⑥ 设置面板
          if (_showSettings)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: _buildSettings(sh),
            ),
        ],
      ),
    );
  }

  Widget _buildSettings(double sh) {
    return Container(
      constraints: BoxConstraints(maxHeight: sh * 0.62),
      decoration: const BoxDecoration(
        color: Color(0xF0181820),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onTap: () => setState(() => _showSettings = false),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.keyboard_arrow_down,
                      color: Colors.white54, size: 28),
                ),
              ),
            ),

            // 提词模式
            Row(
              children: [
                const SizedBox(
                    width: 88,
                    child: Text('提词模式',
                        style: TextStyle(
                            color: Colors.white, fontSize: 15))),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        _modePill('AI语速', _voiceMode, () {
                          if (_isRecording) return;
                          setState(() => _voiceMode = true);
                          _pauseScroll(); // AI模式不预览
                        }),
                        _modePill('匀速', !_voiceMode, () {
                          if (_isRecording) return;
                          setState(() => _voiceMode = false);
                          _startScroll(); // 切到匀速立即开始预览滚动
                        }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // AI语速下:识别语言
            if (_voiceMode) ...[
              Row(
                children: [
                  const SizedBox(
                      width: 88,
                      child: Text('识别语言',
                          style: TextStyle(
                              color: Colors.white, fontSize: 15))),
                  _langRadio('普通话', VoskLang.chinese),
                  const SizedBox(width: 20),
                  _langRadio('英语', VoskLang.english),
                ],
              ),
              const SizedBox(height: 14),
            ],

            // 文字大小
            _sliderRow('文字大小', _fontSize, 16, 72, false,
                (v) => setState(() => _fontSize = v)),

            // 滚动速度(AI模式下禁用;匀速模式下拖动实时预览)
            _speedSliderRow(),

            // 文字颜色
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(
                    width: 88,
                    child: Text('文字颜色',
                        style: TextStyle(
                            color: Colors.white, fontSize: 15))),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: _textColors.map((c) {
                        final isSel = c.value == _textColor.value;
                        return GestureDetector(
                          onTap: () => setState(() => _textColor = c),
                          child: Container(
                            width: 34, height: 34,
                            margin: const EdgeInsets.only(right: 10, top: 5),
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: isSel
                                      ? Colors.white
                                      : Colors.transparent,
                                  width: 3),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            _sliderRow('背景透明', _bgOpacity, 0.0, 0.9, false,
                (v) => setState(() => _bgOpacity = v)),
            _sliderRow('行间距', _lineHeight, 1.2, 2.2, false,
                (v) => setState(() => _lineHeight = v), decimals: 1),
            _sliderRow('左右间距', _hPad, 0, 40, false,
                (v) => setState(() => _hPad = v)),

            // 延迟秒数
            Row(
              children: [
                const SizedBox(
                    width: 88,
                    child: Text('延迟秒数',
                        style: TextStyle(
                            color: Colors.white, fontSize: 15))),
                ...[3, 5, 7, 10].map((s) {
                  final sel = _delaySecs == s;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _delaySecs = s),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel ? Colors.blueAccent : Colors.white10,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${s}s',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14)),
                      ),
                    ),
                  );
                }),
              ],
            ),
            const SizedBox(height: 14),

            // 镜像 + 回到开头
            Row(
              children: [
                const SizedBox(
                    width: 88,
                    child: Text('镜像',
                        style: TextStyle(
                            color: Colors.white, fontSize: 15))),
                Switch(
                  value: _isMirrored,
                  activeColor: Colors.blueAccent,
                  onChanged: (v) => setState(() => _isMirrored = v),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.vertical_align_top,
                      color: Colors.white70, size: 18),
                  label: const Text('回到开头',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 14)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modePill(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF3D5AFE) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 15,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal)),
        ),
      ),
    );
  }

  Widget _langRadio(String label, VoskLang lang) {
    final sel = _selLang == lang;
    return GestureDetector(
      onTap: () {
        if (_isRecording) return;
        setState(() => _selLang = lang);
      },
      child: Row(
        children: [
          Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked,
              color: sel ? const Color(0xFF3D5AFE) : Colors.white38,
              size: 22),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _sliderRow(String label, double value, double min, double max,
      bool disabled, ValueChanged<double> onChanged,
      {int decimals = 0}) {
    return Row(
      children: [
        SizedBox(
            width: 88,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color: disabled ? Colors.white38 : Colors.white,
                        fontSize: 15)),
                Text(value.toStringAsFixed(decimals),
                    style: TextStyle(
                        color: disabled ? Colors.white24 : Colors.white54,
                        fontSize: 12)),
              ],
            )),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            activeColor: disabled ? Colors.white24 : Colors.white,
            inactiveColor: Colors.white24,
            onChanged: disabled ? null : onChanged,
          ),
        ),
      ],
    );
  }

  Widget _speedSliderRow() {
    final disabled = _voiceMode;
    return Row(
      children: [
        SizedBox(
            width: 88,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('滚动速度',
                    style: TextStyle(
                        color: disabled ? Colors.white38 : Colors.white,
                        fontSize: 15)),
                Text(_speed.toStringAsFixed(1),
                    style: TextStyle(
                        color: disabled ? Colors.white24 : Colors.white54,
                        fontSize: 12)),
              ],
            )),
        Expanded(
          child: Slider(
            value: _speed.clamp(0.2, 5.0),
            min: 0.2,
            max: 5.0,
            activeColor: disabled ? Colors.white24 : Colors.white,
            inactiveColor: Colors.white24,
            onChanged:
                disabled ? null : (v) => setState(() => _speed = v),
          ),
        ),
      ],
    );
  }
}

// ====== 编辑稿子全屏页面 ======
class EditScriptPage extends StatefulWidget {
  final String initialTitle;
  final String initialText;
  const EditScriptPage(
      {super.key, required this.initialTitle, required this.initialText});

  @override
  State<EditScriptPage> createState() => _EditScriptPageState();
}

class _EditScriptPageState extends State<EditScriptPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _bodyCtrl = TextEditingController(text: widget.initialText);
    _bodyCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  String get _estimate {
    final text = _bodyCtrl.text;
    int cn = 0;
    int enWords = 0;
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) cn++;
    }
    enWords = RegExp(r'[a-zA-Z]+').allMatches(text).length;
    final secs = cn / 4.0 + enWords / 2.5;
    if (secs < 6) return '';
    final mins = secs / 60.0;
    if (mins < 1) {
      return '预计${secs.round()}秒';
    }
    return '预计${mins.toStringAsFixed(1)}分钟';
  }

  @override
  Widget build(BuildContext context) {
    final count = _bodyCtrl.text.length;
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏:返回 + 完成
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 22),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context, {
                      'title': _titleCtrl.text.trim(),
                      'text': _bodyCtrl.text,
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3D5AFE),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text('完成',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),

            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _titleCtrl,
                maxLines: 1,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  hintText: '输入标题',
                  hintStyle:
                      TextStyle(color: Colors.white24, fontSize: 26),
                  border: InputBorder.none,
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              height: 1,
              color: Colors.white12,
            ),

            // 正文
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 8),
                child: TextField(
                  controller: _bodyCtrl,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 20, height: 1.6),
                  decoration: const InputDecoration(
                    hintText: '输入或粘贴稿子...',
                    hintStyle: TextStyle(color: Colors.white24),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),

            // 底部字数统计
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Text(
                    '$count/30000字${_estimate.isEmpty ? '' : ',$_estimate'}',
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 音浪波形条(自带动画)
class _AudioWave extends StatefulWidget {
  const _AudioWave();

  @override
  State<_AudioWave> createState() => _AudioWaveState();
}

class _AudioWaveState extends State<_AudioWave>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.4),
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(30, (i) {
              final phase = _ctrl.value * 2 * 3.14159 + i * 0.5;
              final h = 6 + 30 * (0.5 + 0.5 * _sin(phase)).abs();
              return Container(
                width: 3,
                height: h,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: Colors.greenAccent,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }

  double _sin(double x) {
    x = x % (2 * 3.14159);
    return x < 3.14159
        ? (16 * x * (3.14159 - x)) /
            (5 * 3.14159 * 3.14159 - 4 * x * (3.14159 - x))
        : -(16 * (x - 3.14159) * (2 * 3.14159 - x)) /
            (5 * 3.14159 * 3.14159 -
                4 * (x - 3.14159) * (2 * 3.14159 - x));
  }
}

class CountdownDialog extends StatefulWidget {
  final int seconds;
  final VoidCallback onComplete;
  const CountdownDialog(
      {super.key, required this.seconds, required this.onComplete});

  @override
  State<CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<CountdownDialog> {
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining <= 1) {
        _timer?.cancel();
        widget.onComplete();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('$_remaining',
          style: const TextStyle(
              fontSize: 120,
              color: Colors.white,
              fontWeight: FontWeight.bold)));
  }
}