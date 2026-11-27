import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/src/diagnostics/github_diagnostics_uploader.dart';

void main() {
  group('GitHubDiagnosticsUploader configuration', () {
    test('remains disabled until both public settings are supplied', () {
      expect(
        GitHubDiagnosticsUploader(
          clientId: '',
          repository: 'owner/private-diagnostics',
        ).isConfigured,
        isFalse,
      );
      expect(
        GitHubDiagnosticsUploader(
          clientId: 'public-client-id',
          repository: '',
        ).isConfigured,
        isFalse,
      );
    });

    test('accepts a configured private repository identifier', () {
      expect(
        GitHubDiagnosticsUploader(
          clientId: 'public-client-id',
          repository: 'owner/private-diagnostics',
        ).isConfigured,
        isTrue,
      );
    });

    test('rejects a URL or path where owner/repository is required', () {
      for (final invalid in [
        'https://github.com/owner/private-diagnostics',
        'owner',
        '../private-diagnostics',
        'owner/private-diagnostics/path',
      ]) {
        expect(
          GitHubDiagnosticsUploader(
            clientId: 'public-client-id',
            repository: invalid,
          ).isConfigured,
          isFalse,
          reason: invalid,
        );
      }
    });
  });
}
