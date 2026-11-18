import 'package:licoup/src/contracts/generated/client_error.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/selection_policy.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// The selection command surface, typed.
///
/// The selection facts and the durable policy are owned by the native host. This
/// gateway carries them: it sends one generated method per operation and returns
/// what the owner answered. It never writes a collection, a file or a register,
/// so the client cannot become a second implementer of a transition the owner
/// already owns, and a policy can only change through `selection.policy.*`.
///
/// The matrix is returned as the owner's document, unparsed. The desktop
/// projection reads that document and fails closed on a revision it does not
/// know, so validating it here would be a second, weaker reading of the same
/// contract.
final class NativeSelectionActions {
  const NativeSelectionActions({
    required NativeStdioRpcTransport stdioRpcTransport,
  }) : _stdioRpcTransport = stdioRpcTransport;

  final NativeStdioRpcTransport _stdioRpcTransport;

  /// The selection matrix for one Agent, exactly as the owner rendered it.
  ///
  /// A target the catalogue cannot observe is a refusal, never an empty matrix:
  /// "could not look" must not reach a surface as "nothing there".
  Future<Map<String, dynamic>> matrixDocument(
    String agent, {
    Map<String, dynamic>? params,
  }) async {
    final result = await _send(
      ConversationProtocolMethod.selectionMatrix,
      <String, dynamic>{'agent': agent, 'params': ?params},
    );
    return _document(result, 'matrix');
  }

  /// The binding the admission boundary captures for a new task.
  Future<SelectionPolicyBinding> policy() async => _binding(
    await _send(
      ConversationProtocolMethod.selectionPolicyGet,
      const <String, dynamic>{},
    ),
  );

  /// Adopt the first revision. The owner refuses a second adoption.
  Future<SelectionPolicyBinding> adopt(
    SelectionPolicyRevision revision,
  ) async => _binding(
    await _send(
      ConversationProtocolMethod.selectionPolicyAdopt,
      <String, dynamic>{'revision': revision.toJson()},
    ),
  );

  /// Replace the revision in force, stating the predecessor it was built on.
  ///
  /// The owner refuses a proposal built on a predecessor that is no longer in
  /// force, so a stale producer cannot overwrite a newer adoption.
  Future<SelectionPolicyBinding> supersede(
    SelectionPolicyRevision revision,
  ) async => _binding(
    await _send(
      ConversationProtocolMethod.selectionPolicySupersede,
      <String, dynamic>{'revision': revision.toJson()},
    ),
  );

  /// Revoke the revision in force and restore the predecessor it recorded.
  ///
  /// The argument is the revision the caller last read, never a guessed one: the
  /// owner revokes only the revision that is actually in force.
  Future<SelectionPolicyBinding> revoke(String revisionId) async {
    if (revisionId.trim().isEmpty) {
      throw const LicoClientRpcException('invalid_params');
    }
    return _binding(
      await _send(
        ConversationProtocolMethod.selectionPolicyRevoke,
        <String, dynamic>{'revisionId': revisionId},
      ),
    );
  }

  Future<Map<String, dynamic>> _send(
    ConversationProtocolMethod method,
    Map<String, dynamic> params,
  ) => _stdioRpcTransport.executeStructured(method.wireName, params);

  /// The document one method's result carries, or a refusal.
  ///
  /// An answer that carries no document at all violates the method's result
  /// contract, which the generated error vocabulary names
  /// [ClientErrorCode.terminalResultInvalid].
  Map<String, dynamic> _document(Map<String, dynamic> result, String key) {
    final document = result[key];
    if (document is! Map<String, dynamic>) {
      throw LicoClientRpcException(
        ClientErrorCode.terminalResultInvalid.wireName,
      );
    }
    return document;
  }

  SelectionPolicyBinding _binding(Map<String, dynamic> result) {
    final binding = SelectionPolicyBinding.parse(_document(result, 'policy'));
    if (binding == null) {
      // The owner's own code for a register it cannot read, so "could not read"
      // is never reported as "nothing is adopted".
      throw LicoClientRpcException(selectionPolicyUnavailableCode);
    }
    return binding;
  }
}

/// The generated code a selection refusal reported.
///
/// The structured transport already decodes the whole frame error into a typed
/// [ClientError]; a transport that reported only a code still resolves through
/// the generated wire table. A code the generated contract does not know stays
/// [ClientErrorCode.unknown], which a caller must treat as a refusal — never as
/// an accepted action.
ClientErrorCode selectionRefusalCode(LicoClientRpcException error) =>
    error.clientError?.code ?? ClientErrorCode.fromWire(error.code);
