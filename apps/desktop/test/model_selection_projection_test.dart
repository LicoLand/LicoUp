import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/model_selection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/model_selection/model_selection_projection.dart';

/// One document with the two facts this surface exists to keep apart: the same
/// Agent is allowed for a direct request and blocked for a workflow turn, and a
/// second model was observed under an Agent the catalogue cannot support.
Map<String, dynamic> _document() => <String, dynamic>{
  'schemaVersion': 1,
  'scopes': ['direct', 'workflow'],
  'agent': 'kimi-code',
  'generation': 'generation-1',
  'observedAtUnixMs': 1726000000000,
  'entries': [
    {
      'agent': 'kimi-code',
      'model': 'k3-256k',
      'canonicalId': 'moonshotai/kimi-k3',
      'canonicalDisplayName': 'Kimi K3',
      'evidence': 'observed',
      'support': {'state': 'supported', 'reason': 'declared_identity'},
      'availability': {
        'state': 'observed',
        'reason': 'observed_by_live_source',
        'observedAtUnixMs': 1726000000000,
      },
      'credentials': {
        'state': 'present',
        'reason': 'provider_credential_present',
      },
      'providers': ['kimi-for-coding'],
      'scopes': [
        {
          'scope': 'direct',
          'state': 'allowed',
          'reason': 'direct_request_admitted',
        },
        {
          'scope': 'workflow',
          'state': 'blocked',
          'reason': 'workflow_policy_disallows_agent',
        },
      ],
    },
    {
      'agent': 'kimi-code',
      'model': 'mystery-preview',
      'canonicalId': null,
      'canonicalDisplayName': null,
      'evidence': 'observed',
      'support': {
        'state': 'unknown',
        'reason': 'observed_without_declared_identity',
      },
      'availability': {
        'state': 'observed',
        'reason': 'observed_by_live_source',
        'observedAtUnixMs': 1726000000000,
      },
      'credentials': {'state': 'unknown', 'reason': 'provider_not_recorded'},
      'providers': <String>[],
      'scopes': [
        {
          'scope': 'direct',
          'state': 'undetermined',
          'reason': 'selection_policy_owner_absent',
        },
        {
          'scope': 'workflow',
          'state': 'undetermined',
          'reason': 'selection_policy_owner_absent',
        },
      ],
    },
  ],
};

void main() {
  test('one Agent keeps differing direct and workflow outcomes apart', () {
    final projection = ModelSelectionProjection.fromDocument(
      _document(),
      agent: 'kimi-code',
    );
    expect(projection.phase, PresentationPhase.ready);
    expect(projection.entries, hasLength(2));

    final declared = projection.entries.first;
    final direct = declared.outcomeFor('direct');
    final workflow = declared.outcomeFor('workflow');
    expect(direct, isNotNull);
    expect(workflow, isNotNull);
    expect(direct!.state, ModelSelectionScopeState.allowed);
    expect(direct.executes, isTrue);
    expect(direct.label, ModelSelectionLabels.scopeAllowed);
    expect(direct.reason, 'direct_request_admitted');
    expect(workflow!.state, ModelSelectionScopeState.blocked);
    expect(workflow.executes, isFalse);
    expect(workflow.label, ModelSelectionLabels.scopeBlocked);
    expect(
      workflow.reason,
      'workflow_policy_disallows_agent',
      reason: 'a blocked scope keeps its own reason beside the allowed one',
    );

    // The two scopes are separate facts on one Agent: one being allowed never
    // promotes the other.
    expect(projection.executesIn('direct'), isTrue);
    expect(projection.executesIn('workflow'), isFalse);
  });

  test('every dimension is labelled separately and never collapsed', () {
    final projection = ModelSelectionProjection.fromDocument(
      _document(),
      agent: 'kimi-code',
    );
    final declared = projection.entries.first;
    expect(declared.supportState, ModelSelectionSupportState.supported);
    expect(declared.supportLabel, ModelSelectionLabels.supportSupported);
    expect(declared.supportReason, 'declared_identity');
    expect(
      declared.availabilityState,
      ModelSelectionAvailabilityState.observed,
    );
    expect(
      declared.availabilityLabel,
      ModelSelectionLabels.availabilityObserved,
    );
    expect(declared.observedAtUnixMs, 1726000000000);
    expect(declared.credentialState, ModelSelectionCredentialState.present);
    expect(declared.credentialLabel, ModelSelectionLabels.credentialPresent);

    // Support, availability and credentials are three independent statements;
    // none of them is the readiness label the targets surface shows.
    expect(
      declared.supportLabel == declared.availabilityLabel,
      isFalse,
      reason: 'support and availability must not render as one label',
    );

    final observedWithoutIdentity = projection.entries.last;
    expect(
      observedWithoutIdentity.supportState,
      ModelSelectionSupportState.unknown,
      reason: 'an observed name nothing declares is not a support claim',
    );
    expect(
      observedWithoutIdentity.supportLabel,
      ModelSelectionLabels.supportUnknown,
    );
    expect(
      observedWithoutIdentity.displayName,
      'mystery-preview',
      reason: 'a model without a canonical identity falls back to its name',
    );
  });

  test('an unobserved model is never reported as available or ready', () {
    final document = _document();
    final entries = document['entries']! as List<dynamic>;
    entries.add(<String, dynamic>{
      'agent': 'kimi-code',
      'model': 'declared-but-absent',
      'canonicalId': 'moonshotai/kimi-k3',
      'canonicalDisplayName': 'Kimi K3',
      'evidence': 'declaredOnly',
      'support': {'state': 'supported', 'reason': 'declared_identity'},
      'availability': {
        'state': 'unobserved',
        'reason': 'not_observed_on_this_host',
        'observedAtUnixMs': null,
      },
      'credentials': {
        'state': 'unknown',
        'reason': 'provider_credential_unknown',
      },
      'providers': ['kimi-for-coding'],
      'scopes': [
        {
          'scope': 'direct',
          'state': 'undetermined',
          'reason': 'selection_policy_owner_absent',
        },
        {
          'scope': 'workflow',
          'state': 'undetermined',
          'reason': 'selection_policy_owner_absent',
        },
      ],
    });
    final projection = ModelSelectionProjection.fromDocument(
      document,
      agent: 'kimi-code',
    );
    final unobserved = projection.entries.last;
    expect(unobserved.supportState, ModelSelectionSupportState.supported);
    expect(
      unobserved.availabilityState,
      ModelSelectionAvailabilityState.unobserved,
      reason: 'a supported model nobody observed is still not available',
    );
    expect(unobserved.observedAtUnixMs, isNull);
    expect(
      unobserved.outcomeFor('direct')!.state,
      ModelSelectionScopeState.undetermined,
    );
    expect(
      projection.executesIn('direct'),
      isTrue,
      reason: 'the first entry states allowed',
    );
  });

  test('an unsupported combination is distinct from an unexecutable one', () {
    final projection = ModelSelectionProjection.fromDocument(
      _document(),
      agent: 'kimi-code',
    );
    final undeclared = projection.entries.last;
    // Nothing declares this name, so it is unsupported: a catalogue statement.
    expect(undeclared.supportState, ModelSelectionSupportState.unknown);
    // The same entry has no stated policy outcome: a policy statement, and a
    // different fact from the support state above.
    expect(
      undeclared.outcomeFor('direct')!.state,
      ModelSelectionScopeState.undetermined,
    );
    expect(undeclared.outcomeFor('direct')!.executes, isFalse);
    expect(
      undeclared.supportState == undeclared.outcomeFor('direct')!.state,
      isFalse,
      reason: 'support and execution are separate dimensions',
    );
  });

  test(
    'a scope the document omitted is stated as not recorded, never allowed',
    () {
      final document = _document();
      final entries = document['entries']! as List<dynamic>;
      final first = entries.first! as Map<String, dynamic>;
      first['scopes'] = [
        {
          'scope': 'direct',
          'state': 'allowed',
          'reason': 'direct_request_admitted',
        },
      ];
      final projection = ModelSelectionProjection.fromDocument(
        document,
        agent: 'kimi-code',
      );
      final workflow = projection.entries.first.outcomeFor('workflow');
      expect(workflow, isNotNull);
      expect(workflow!.state, ModelSelectionScopeState.undetermined);
      expect(workflow.reason, modelSelectionScopeNotRecordedReason);
      expect(workflow.executes, isFalse);
    },
  );

  test('a document the contract refuses fails instead of reading as empty', () {
    for (final document in <Object?>[
      null,
      'not a document',
      <String, dynamic>{'schemaVersion': 2, 'entries': <dynamic>[]},
      <String, dynamic>{'schemaVersion': 1},
    ]) {
      final projection = ModelSelectionProjection.fromDocument(
        document,
        agent: 'kimi-code',
      );
      expect(projection.phase, PresentationPhase.failed, reason: '$document');
      expect(projection.entries, isEmpty);
      expect(
        projection.notice?.reasonCode,
        modelSelectionUnavailableNoticeCode,
      );
    }
  });

  test('the contract refuses a document of another revision', () {
    expect(ModelSelectionMatrix.parse(_document()), isNotNull);
    expect(
      ModelSelectionMatrix.parse(<String, dynamic>{
        'schemaVersion': 2,
        'entries': <dynamic>[],
      }),
      isNull,
    );
    expect(
      ModelSelectionMatrix.parse(<String, dynamic>{'entries': <dynamic>[]}),
      isNull,
    );
  });

  test('a malformed state never reads as a positive one', () {
    final entry = ModelSelectionEntry.fromJson(<String, dynamic>{
      'agent': 'kimi-code',
      'model': 'k3-256k',
      'support': {'state': 'totally-unsupported', 'reason': 'weird'},
      'availability': {'state': 'probably', 'observedAtUnixMs': -1},
      'credentials': {'state': '', 'reason': ''},
      'scopes': [
        {'scope': 'direct', 'state': 'yes', 'reason': ''},
      ],
    });
    expect(entry.support.state, ModelSelectionSupportState.unknown);
    expect(
      entry.availability.state,
      ModelSelectionAvailabilityState.unobserved,
    );
    expect(entry.availability.observedAtUnixMs, isNull);
    expect(entry.credentials.state, ModelSelectionCredentialState.unknown);
    expect(entry.credentials.reason, modelSelectionUnavailableCode);
    expect(
      entry.outcomeFor('direct')!.state,
      ModelSelectionScopeState.undetermined,
    );
    expect(
      entry.outcomeFor('workflow')!.reason,
      modelSelectionScopeNotRecordedReason,
    );
  });
}
