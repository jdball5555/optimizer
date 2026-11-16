import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:optimizer/ai/ai_client.dart';

void main() {
  late http.Request sent;
  void reply(int status, Map<String, dynamic> body) => AiClient.transport = MockClient((r) async {
        sent = r;
        return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
      });

  Future<String> ask(AiProvider p, {String? model}) => AiClient.ask(
        provider: p,
        apiKey: 'KEY',
        model: model ?? p.defaultModel,
        system: 'You help.',
        turns: const [AiTurn(true, 'Hi'), AiTurn(false, 'Hello!'), AiTurn(true, 'What is due?')],
      );

  test('Claude: request shape and answer', () async {
    reply(200, {
      'content': [
        {'type': 'thinking', 'thinking': ''},
        {'type': 'text', 'text': 'Essay 2 is due tomorrow.'},
      ],
      'stop_reason': 'end_turn',
    });
    expect(await ask(AiProvider.claude), 'Essay 2 is due tomorrow.');
    expect(sent.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(sent.headers['x-api-key'], 'KEY');
    expect(sent.headers['anthropic-version'], '2026-10-21');
    expect(sent.headers['anthropic-dangerous-direct-browser-access'], 'true');
    expect(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
    final body = jsonDecode(sent.body) as Map;
    expect(body['model'], 'claude-opus-5-5');
    expect(body['system'], 'You help.');
    expect(body['fallbacks'], 'default');
    expect(body['output_config'], {'effort': 'medium'});
    expect(body.containsKey('thinking'), isFalse);
    expect([for (final m in body['messages'] as List) m['role']], ['user', 'assistant', 'user']);
  });

  test('Claude: a model without effort or fallbacks gets neither', () async {
    reply(200, {'content': [{'type': 'text', 'text': 'ok'}], 'stop_reason': 'end_turn'});
    await ask(AiProvider.claude, model: 'claude-haiku-4-5');
    final body = jsonDecode(sent.body) as Map;
    expect(body.containsKey('output_config'), isFalse);
    expect(body.containsKey('fallbacks'), isFalse);
    expect(sent.headers.containsKey('anthropic-beta'), isFalse);
  });

  test('Claude: refusals and bad keys read as plain messages', () async {
    reply(200, {'content': [], 'stop_reason': 'refusal'});
    expect(() => ask(AiProvider.claude), throwsA(isA<AiException>().having((e) => e.message, 'message', contains('declined'))));
    reply(401, {'type': 'error', 'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}});
    expect(() => ask(AiProvider.claude), throwsA(isA<AiException>().having((e) => e.message, 'message', contains('API key'))));
  });

  test('Gemini: request shape and answer', () async {
    reply(200, {
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'Two things are due.'},
            ],
          },
        },
      ],
    });
    expect(await ask(AiProvider.gemini), 'Two things are due.');
    expect(sent.url.toString(), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent');
    expect(sent.headers['x-goog-api-key'], 'KEY');
    final body = jsonDecode(sent.body) as Map;
    expect((body['systemInstruction'] as Map)['parts'], [
      {'text': 'You help.'},
    ]);
    expect([for (final c in body['contents'] as List) c['role']], ['user', 'model', 'user']);
  });

  test('model lists from both providers', () async {
    reply(200, {
      'data': [
        {'id': 'claude-opus-5-5', 'display_name': 'Claude Opus 5.5'},
        {'id': 'claude-haiku-5-5', 'display_name': 'Claude Haiku 5.5'},
      ],
    });
    expect(await AiClient.models(AiProvider.claude, 'KEY'), [('claude-opus-5-5', 'Claude Opus 5.5'), ('claude-haiku-5-5', 'Claude Haiku 5.5')]);
    expect(sent.url.toString(), 'https://api.anthropic.com/v1/models?limit=100');
    reply(200, {
      'models': [
        {'name': 'models/gemini-flash-latest', 'displayName': 'Gemini Flash', 'supportedGenerationMethods': ['generateContent']},
        {'name': 'models/text-embedding-004', 'displayName': 'Embedding', 'supportedGenerationMethods': ['embedContent']},
      ],
    });
    expect(await AiClient.models(AiProvider.gemini, 'KEY'), [('gemini-flash-latest', 'Gemini Flash')]);
    reply(401, {'error': {'message': 'invalid x-api-key'}});
    expect(() => AiClient.models(AiProvider.claude, 'BAD'), throwsA(isA<AiException>()));
  });
}
