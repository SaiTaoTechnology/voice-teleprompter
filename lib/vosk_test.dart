import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:permission_handler/permission_handler.dart';

class VoskTestScreen extends StatefulWidget {
  const VoskTestScreen({super.key});

  @override
  State<VoskTestScreen> createState() => _VoskTestScreenState();
}

class _VoskTestScreenState extends State<VoskTestScreen> {
  static const _modelAssetPath =
      'assets/models/vosk-model-small-en-us-0.15.zip';
  static const _sampleRate = 16000;

  final _vosk = VoskFlutterPlugin.instance();
  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;

  String _status = '初始化中...';
  String _partial = '';
  String _finalText = '';
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      // 申请麦克风权限
      setState(() => _status = '申请麦克风权限...');
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        setState(() => _status = '❌ 没有麦克风权限');
        return;
      }

      // 加载模型
      setState(() => _status = '加载模型...');
      final modelLoader = ModelLoader();
      final modelPath = await modelLoader.loadFromAssets(_modelAssetPath);
      _model = await _vosk.createModel(modelPath);

      // 创建识别器
      setState(() => _status = '创建识别器...');
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: _sampleRate,
      );

      // 创建语音服务
      setState(() => _status = '创建语音服务...');
      _speechService = await _vosk.initSpeechService(_recognizer!);

      // 监听结果
      _speechService!.onPartial().listen((partialJson) {
        try {
          final m = jsonDecode(partialJson);
          setState(() => _partial = m['partial'] ?? '');
        } catch (_) {}
      });

      _speechService!.onResult().listen((resultJson) {
        try {
          final m = jsonDecode(resultJson);
          final txt = (m['text'] ?? '').toString().trim();
          if (txt.isNotEmpty) {
            setState(() {
              _finalText = '$_finalText $txt'.trim();
              _partial = '';
            });
          }
        } catch (_) {}
      });

      setState(() => _status = '✅ 准备就绪，点下面按钮开始');
    } catch (e) {
      setState(() => _status = '❌ 初始化失败: $e');
    }
  }

  Future<void> _toggle() async {
    if (_speechService == null) return;
    if (_listening) {
      await _speechService!.stop();
      setState(() => _listening = false);
    } else {
      await _speechService!.start();
      setState(() => _listening = true);
    }
  }

  @override
  void dispose() {
    _speechService?.dispose();
    _recognizer?.dispose();
    _model?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vosk 测试')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status,
                style: const TextStyle(fontSize: 14, color: Colors.grey)),
            const SizedBox(height: 24),
            const Text('实时识别(partial):',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(top: 4, bottom: 16),
              decoration: BoxDecoration(
                color: Colors.yellow.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              constraints: const BoxConstraints(minHeight: 60),
              child: Text(_partial,
                  style: const TextStyle(fontSize: 18, color: Colors.orange)),
            ),
            const Text('完整结果(result):',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: Text(_finalText,
                      style: const TextStyle(fontSize: 18)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _speechService == null ? null : _toggle,
              style: ElevatedButton.styleFrom(
                backgroundColor: _listening ? Colors.red : Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(
                _listening ? '⏹ 停止' : '🎤 开始说话',
                style: const TextStyle(fontSize: 18, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}