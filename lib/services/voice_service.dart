import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

class VoiceService {
  static final VoiceService _instance = VoiceService._internal();
  factory VoiceService() => _instance;
  VoiceService._internal();

  final SpeechToText _speechToText = SpeechToText();
  bool _isAvailable = false;
  String _lastError = '';

  bool get isAvailable => _isAvailable;
  bool get isListening => _speechToText.isListening;
  String get lastError => _lastError;

  Future<bool> initialize() async {
    if (_isAvailable) return true;

    try {
      _isAvailable = await _speechToText.initialize(
        onError: (val) {
          _lastError = val.errorMsg;
          debugPrint('SpeechToText error: ${val.errorMsg}');
        },
        onStatus: (val) {
          debugPrint('SpeechToText status: $val');
        },
      );
      return _isAvailable;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('Error inicializando SpeechToText: $e');
      _isAvailable = false;
      return false;
    }
  }

  Future<void> startListening({
    required Function(String recognizedWords, bool isFinal) onResult,
  }) async {
    if (!_isAvailable) {
      final ok = await initialize();
      if (!ok) return;
    }

    try {
      await _speechToText.listen(
        onResult: (result) {
          onResult(result.recognizedWords, result.finalResult);
        },
        listenOptions: SpeechListenOptions(
          cancelOnError: true,
          listenMode: ListenMode.confirmation,
          localeId: 'es_ES',
        ),
      );
    } catch (e) {
      debugPrint('Error al escuchar voz: $e');
    }
  }

  Future<void> stopListening() async {
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }
  }
}
