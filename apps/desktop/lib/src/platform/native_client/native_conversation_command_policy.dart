/// The generic command runner is a stateless boundary. Conversation namespaces
/// are admitted only by the semantic conversation port, including when an
/// injected one-shot executor is present.
bool nativeCliTargetsConversation(List<String> arguments) =>
    switch (arguments) {
      ['agent', 'conversation', ...] || ['conversation', ...] => true,
      _ => false,
    };
