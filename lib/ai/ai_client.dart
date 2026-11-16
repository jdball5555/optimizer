import 'dart:convert';

import 'package:http/http.dart' as http;

enum AiProvider {
  claude('Claude', 'claude-opus-5-5'),
  gemini('Gemini', 'gemini-flash-latest');

  const AiProvider(this.label, this.defaultModel);
  final String label;
  final String defaultModel;
}

class AiTurn {
  const AiTurn(this.fromUser, this.text);
  final bool fromUser;
  final String text;
}

class AiException implements Exception {
  AiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One request to the AI you chose, with your own API key, straight from
/// this device to Anthropic or Google (no server of ours in between).
class AiClient {
  /// Swapped for a fake in tests.
  static http.Client transport = http.Client();

  static Future<String> ask({
    required AiProvider provider,
    required String apiKey,
    required String model,
    required String system,
    required List<AiTurn> turns,
  }) =>
      switch (provider) {
        AiProvider.claude => _claude(apiKey, model, system, turns),
        AiProvider.gemini => _gemini(apiKey, model, system, turns),
      };

  // Models that take output_config.effort and the server-side refusal fallback.
  static bool _modern(String model) => RegExp(r'^claude-(opus-5|sonnet-5|fable|haiku-5|opus-4-[678])').hasMatch(model);
  static bool _fallbacks(String model) =>
      const ['claude-opus-5-5', 'claude-opus-5', 'claude-fable-5-1', 'claude-sonnet-5-5'].contains(model);

  static Future<String> _claude(String key, String model, String system, List<AiTurn> turns) async {
    final http.Response r;
    try {
      r = await transport
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': key,
              'anthropic-version': '2026-10-21',
              // Lets the browser build call Anthropic directly with your key.
              'anthropic-dangerous-direct-browser-access': 'true',
              // If a request is declined, Anthropic retries it on its recommended fallback model.
              if (_fallbacks(model)) 'anthropic-beta': 'server-side-fallback-2026-07-01',
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': 16000,
              'system': system,
              'messages': [
                for (final t in turns) {'role': t.fromUser ? 'user' : 'assistant', 'content': t.text},
              ],
              if (_modern(model)) 'output_config': {'effort': 'medium'},
              if (_fallbacks(model)) 'fallbacks': 'default',
            }),
          )
          .timeout(const Duration(minutes: 4));
    } catch (e) {
      throw AiException('Couldn’t reach Claude ($e).');
    }
    final body = _json(r.body);
    if (r.statusCode != 200) {
      final err = body['error'] is Map ? body['error'] as Map : const {};
      throw AiException(switch (r.statusCode) {
        401 => 'Claude didn’t accept that API key. Check it in Settings → AI.',
        403 => 'This API key isn’t allowed to do that (${err['message'] ?? 'permission error'}).',
        404 => 'Claude doesn’t know the model “$model”. Check the model in Settings → AI.',
        429 => 'Too many requests for your API key right now. Try again in a moment.',
        529 || 503 => 'Claude is overloaded right now. Try again in a moment.',
        _ => 'Claude error ${r.statusCode}: ${err['message'] ?? r.body}',
      });
    }
    if (body['stop_reason'] == 'refusal') {
      throw AiException('Claude declined to answer that one.');
    }
    final text = [
      for (final b in (body['content'] as List? ?? const []))
        if (b is Map && b['type'] == 'text') '${b['text']}',
    ].join('\n').trim();
    if (body['stop_reason'] == 'max_tokens') return '$text\n\n(The answer was cut off at its length limit.)';
    return text.isEmpty ? '(No answer.)' : text;
  }

  static Future<String> _gemini(String key, String model, String system, List<AiTurn> turns) async {
    final http.Response r;
    try {
      r = await transport
          .post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
            headers: {'content-type': 'application/json', 'x-goog-api-key': key},
            body: jsonEncode({
              'systemInstruction': {
                'parts': [
                  {'text': system},
                ],
              },
              'contents': [
                for (final t in turns)
                  {
                    'role': t.fromUser ? 'user' : 'model',
                    'parts': [
                      {'text': t.text},
                    ],
                  },
              ],
            }),
          )
          .timeout(const Duration(minutes: 4));
    } catch (e) {
      throw AiException('Couldn’t reach Gemini ($e).');
    }
    final body = _json(r.body);
    if (r.statusCode != 200) {
      final err = body['error'] is Map ? body['error'] as Map : const {};
      throw AiException(switch (r.statusCode) {
        400 when '${err['message']}'.contains('API key') => 'Gemini didn’t accept that API key. Check it in Settings → AI.',
        401 || 403 => 'Gemini didn’t accept that API key. Check it in Settings → AI.',
        404 => 'Gemini doesn’t know the model “$model”. Check the model in Settings → AI.',
        429 => 'Too many requests for your API key right now. Try again in a moment.',
        _ => 'Gemini error ${r.statusCode}: ${err['message'] ?? r.body}',
      });
    }
    final block = (body['promptFeedback'] as Map?)?['blockReason'];
    if (block != null) throw AiException('Gemini declined to answer that one ($block).');
    final parts = (((body['candidates'] as List?)?.firstOrNull as Map?)?['content'] as Map?)?['parts'] as List? ?? const [];
    final text = [for (final p in parts) if (p is Map && p['text'] != null) '${p['text']}'].join().trim();
    return text.isEmpty ? '(No answer.)' : text;
  }

  /// Every model your key can use: (id, name), newest first as each provider lists them.
  static Future<List<(String, String)>> models(AiProvider provider, String apiKey) async {
    final http.Response r;
    try {
      r = switch (provider) {
        AiProvider.claude => await transport.get(Uri.parse('https://api.anthropic.com/v1/models?limit=100'), headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2026-10-21',
            'anthropic-dangerous-direct-browser-access': 'true',
          }),
        AiProvider.gemini => await transport.get(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200'),
            headers: {'x-goog-api-key': apiKey},
          ),
      };
    } catch (e) {
      throw AiException('Couldn’t reach ${provider.label} ($e).');
    }
    final body = _json(r.body);
    if (r.statusCode == 401 || r.statusCode == 403 || (r.statusCode == 400 && '${body['error']}'.contains('API key'))) {
      throw AiException('${provider.label} didn’t accept that API key.');
    }
    if (r.statusCode != 200) throw AiException('${provider.label} error ${r.statusCode}.');
    return switch (provider) {
      AiProvider.claude => [
          for (final m in (body['data'] as List? ?? const []))
            if (m is Map && m['id'] is String) ('${m['id']}', '${m['display_name'] ?? m['id']}'),
        ],
      AiProvider.gemini => [
          for (final m in (body['models'] as List? ?? const []))
            if (m is Map && (m['supportedGenerationMethods'] as List? ?? const []).contains('generateContent'))
              ('${m['name']}'.replaceFirst('models/', ''), '${m['displayName'] ?? m['name']}'),
        ],
    };
  }

  static Map<String, dynamic> _json(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }
}
