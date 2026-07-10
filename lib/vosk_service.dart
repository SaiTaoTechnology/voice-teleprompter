import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

enum VoskLang { english, chinese }

class VoskService extends ChangeNotifier {
  static const _enModel = 'assets/models/vosk-model-small-en-us-0.15.zip';
  static const _cnModel = 'assets/models/vosk-model-small-cn.zip';
  static const _sampleRate = 16000;

  final _vosk = VoskFlutterPlugin.instance();

  VoskLang _lang = VoskLang.english;
  VoskLang get lang => _lang;

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;

  bool _ready = false;
  bool get ready => _ready;

  bool _listening = false;
  bool get listening => _listening;

  String _partial = '';
  String get partial => _partial;

  String _lastResult = '';
  String get lastResult => _lastResult;

  String _status = '未初始化';
  String get status => _status;

  // 外部注册的回调:每次识别出新词时调用,传入识别到的文本
  void Function(String text)? onRecognized;

  Future<void> init(VoskLang lang) async {
    await _cleanup();
    _lang = lang;
    _ready = false;
    _setStatus('申请麦克风权限...');

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _setStatus('❌ 没有麦克风权限');
      return;
    }

    try {
      _setStatus('加载模型...');
      final modelPath = await ModelLoader().loadFromAssets(
        lang == VoskLang.english ? _enModel : _cnModel,
      );
      _model = await _vosk.createModel(modelPath);

      _setStatus('创建识别器...');
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: _sampleRate,
      );

      _setStatus('初始化语音服务...');
      _speechService = await _vosk.initSpeechService(_recognizer!);

      _speechService!.onPartial().listen((json) {
        try {
          final m = jsonDecode(json);
          _partial = m['partial'] ?? '';
          onRecognized?.call(_partial);
          notifyListeners();
        } catch (_) {}
      });

      _speechService!.onResult().listen((json) {
        try {
          final m = jsonDecode(json);
          final txt = (m['text'] ?? '').toString().trim();
          if (txt.isNotEmpty) {
            _lastResult = txt;
            onRecognized?.call(txt);
            notifyListeners();
          }
        } catch (_) {}
      });

      _ready = true;
      _setStatus('✅ 就绪');
    } catch (e) {
      _setStatus('❌ 初始化失败: $e');
    }
  }

  Future<void> start() async {
    if (!_ready || _speechService == null || _listening) return;
    await _speechService!.start();
    _listening = true;
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_listening || _speechService == null) return;
    await _speechService!.stop();
    _listening = false;
    _partial = '';
    notifyListeners();
  }

  Future<void> switchLang(VoskLang lang) async {
    if (_listening) await stop();
    await init(lang);
  }

  Future<void> _cleanup() async {
    _listening = false;
    _ready = false;
    await _speechService?.stop();
    _speechService?.dispose();
    _recognizer?.dispose();
    _model?.dispose();
    _speechService = null;
    _recognizer = null;
    _model = null;
  }

  void _setStatus(String s) {
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}