import 'package:flutter_test/flutter_test.dart';
import 'package:mindfeed_mobile/services/ai/llm_profile.dart';
import 'package:mindfeed_mobile/services/ai/llm_profiles_store.dart';
import 'package:mindfeed_mobile/services/openrouter_service.dart';

void main() {
  group('LlmProfile', () {
    test('JSON-Roundtrip', () {
      final p = LlmProfile.groq('id-1').copyWith(
          model: 'llama-3.3-70b-versatile',
          tier: LlmTier.paid,
          supportsVision: true);
      final back = LlmProfile.fromJson(p.toJson());
      expect(back.id, 'id-1');
      expect(back.kind, ProviderKind.groq);
      expect(back.tier, LlmTier.paid);
      expect(back.supportsVision, isTrue);
      expect(back.chatUrl, 'https://api.groq.com/openai/v1/chat/completions');
      expect(back.modelsUrl, 'https://api.groq.com/openai/v1/models');
    });

    test('lokale Anbieter brauchen keinen Key', () {
      expect(LlmProfile.ollama('x').needsApiKey, isFalse);
      expect(LlmProfile.openRouter('y').needsApiKey, isTrue);
    });
  });

  group('Task-Ketten', () {
    final or = LlmProfile.openRouter('a');
    final gq = LlmProfile.groq('b');
    final state = LlmProfilesState(
      profiles: [or, gq],
      defaultProfileId: or.id,
      taskAssignment:
          const LlmTaskAssignment().withChain(LlmTask.enrichment, ['b']),
    );

    test('chainFor liefert Kette + Default als Schluss-Fallback', () {
      final chain = state.chainFor(LlmTask.enrichment);
      expect(chain.map((p) => p.id).toList(), ['b', 'a']); // groq, dann default
    });

    test('ohne Kette nur Default', () {
      expect(state.chainFor(LlmTask.vision).map((p) => p.id).toList(), ['a']);
    });
  });

  group('AiUnavailableException', () {
    test('retrybare Status', () {
      for (final s in [429, 402, 404, 500, 503]) {
        expect(AiUnavailableException.isRetryableStatus(s), isTrue, reason: '$s');
      }
      expect(AiUnavailableException.isRetryableStatus(400), isFalse);
    });

    test('Retry-After (Sekunden) wird gelesen', () {
      final d = AiUnavailableException.retryAfterFrom({'retry-after': '42'});
      expect(d, const Duration(seconds: 42));
    });

    test('isLimit nur bei 429/402', () {
      expect(const AiUnavailableException(429, 'x').isLimit, isTrue);
      expect(const AiUnavailableException(402, 'x').isLimit, isTrue);
      expect(const AiUnavailableException(500, 'x').isLimit, isFalse);
    });
  });
}
