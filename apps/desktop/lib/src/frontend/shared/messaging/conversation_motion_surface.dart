import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';

/// A local overlay shared by a conversation and its composer. Desktop places
/// it above both siblings; a standalone scene creates its own host.
class ConversationMotionHost extends StatefulWidget {
  const ConversationMotionHost({super.key, required this.child});
  final Widget child;

  @override
  State<ConversationMotionHost> createState() => _ConversationMotionHostState();
}

class _ConversationMotionHostState extends State<ConversationMotionHost> {
  final _registry = _MotionRegistry();
  final _surfaceKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _registry.surface = () => _surfaceKey.currentContext?.findRenderObject();
  }

  @override
  void dispose() {
    _registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MotionHostScope(
    registry: _registry,
    child: NotificationListener<ConversationMotionSubmitNotification>(
      onNotification: (_) {
        _registry.notifySubmit();
        return true;
      },
      child: _MotionSurfaceObserver(
        key: _surfaceKey,
        registry: _registry,
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _registry.schedule();
            return false;
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              Positioned.fill(
                child: ValueListenableBuilder<_MotionPresentation?>(
                  valueListenable: _registry.presentation,
                  builder: (context, presentation, _) {
                    if (presentation == null) return const SizedBox.shrink();
                    return Offstage(
                      offstage: !presentation.enabled,
                      child: TickerMode(
                        enabled: presentation.enabled,
                        child: ConversationParticleField(
                          key: ValueKey(presentation.identity),
                          assembled: presentation.assembled,
                          anchors: presentation.anchors,
                          avatarGlyph: presentation.glyph,
                          onAssembled: presentation.onAssembled,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A content-free presentation event from a validated composer submission.
/// Sending and reply rendering never wait for its decorative listeners.
class ConversationMotionSubmitNotification extends Notification {
  const ConversationMotionSubmitNotification();
}

class _MotionSurfaceObserver extends SingleChildRenderObjectWidget {
  const _MotionSurfaceObserver({
    super.key,
    required this.registry,
    required super.child,
  });
  final _MotionRegistry registry;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMotionSurface(registry);
}

class _RenderMotionSurface extends RenderProxyBox {
  _RenderMotionSurface(this.registry);
  final _MotionRegistry registry;

  @override
  void performLayout() {
    super.performLayout();
    registry.schedule();
  }
}

/// The caller owns the empty/first-send decision and the visual identity.
/// Keep [conversationKey] stable through a real draft-to-session rollover, and
/// replace it when switching conversations. Completion only removes decoration.
class ConversationMotionScene extends StatelessWidget {
  const ConversationMotionScene({
    super.key,
    required this.conversationKey,
    required this.visible,
    required this.assembled,
    required this.child,
    this.onAssembled,
    this.onSendInitiated,
  });
  final Object conversationKey;
  final bool visible;
  final bool assembled;
  final Widget child;
  final VoidCallback? onAssembled;
  final VoidCallback? onSendInitiated;

  @override
  Widget build(BuildContext context) {
    final registration = _MotionSceneRegistration(scene: this, child: child);
    return _MotionHostScope.maybeOf(context) == null
        ? ConversationMotionHost(child: registration)
        : registration;
  }
}

/// Marks the transcript viewport, excluding sidebars and the composer.
class ConversationMotionContent extends StatelessWidget {
  const ConversationMotionContent({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _MotionAnchor(role: _MotionAnchorRole.content, child: child);
}

/// Only the selected first reply receives this scope. Historical avatars do
/// not register destinations merely because they appear in the same viewport.
class ConversationMotionAvatarTarget extends InheritedWidget {
  const ConversationMotionAvatarTarget({super.key, required super.child});

  static bool isTarget(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<
            ConversationMotionAvatarTarget
          >() !=
      null;

  @override
  bool updateShouldNotify(ConversationMotionAvatarTarget oldWidget) => false;
}

/// Wrap only the app-rendered transparent brand mark, never message text,
/// avatar wells, badges, or user-authored imagery.
class ConversationMotionBrandMark extends StatelessWidget {
  const ConversationMotionBrandMark({
    super.key,
    required this.glyphIdentity,
    required this.child,
  });
  final Object glyphIdentity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!ConversationMotionAvatarTarget.isTarget(context)) return child;
    return _MotionAnchor(
      role: _MotionAnchorRole.avatar,
      glyphIdentity: glyphIdentity,
      child: child,
    );
  }
}

/// Measures the actual field and the animated radius used by its rim.
class ConversationMotionComposerOutline extends StatelessWidget {
  const ConversationMotionComposerOutline({
    super.key,
    required this.borderRadius,
    required this.child,
  });
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) => _MotionAnchor(
    role: _MotionAnchorRole.composer,
    radius: borderRadius,
    child: child,
  );
}

class _MotionSceneRegistration extends StatefulWidget {
  const _MotionSceneRegistration({required this.scene, required this.child});
  final ConversationMotionScene scene;
  final Widget child;

  @override
  State<_MotionSceneRegistration> createState() =>
      _MotionSceneRegistrationState();
}

class _MotionSceneRegistrationState extends State<_MotionSceneRegistration> {
  _MotionRegistry? _registry;
  bool _completed = false;
  bool _tickerEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = _MotionHostScope.maybeOf(context)!;
    if (registry != _registry) {
      _registry?.removeScene(this);
      _registry = registry;
      registry.scenes.add(this);
    }
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    registry.schedule();
  }

  @override
  void didUpdateWidget(_MotionSceneRegistration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scene.conversationKey != widget.scene.conversationKey ||
        (!oldWidget.scene.visible && widget.scene.visible)) {
      _completed = false;
    }
    _registry?.schedule();
  }

  void _complete(Object identity) {
    if (!mounted || identity != widget.scene.conversationKey || _completed) {
      return;
    }
    _completed = true;
    _registry?.schedule();
    widget.scene.onAssembled?.call();
  }

  @override
  void dispose() {
    _registry?.removeScene(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _MotionSceneScope(scene: this, child: widget.child);
}

class _MotionHostScope extends InheritedWidget {
  const _MotionHostScope({required this.registry, required super.child});
  final _MotionRegistry registry;
  static _MotionRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MotionHostScope>()?.registry;

  @override
  bool updateShouldNotify(_MotionHostScope oldWidget) =>
      registry != oldWidget.registry;
}

class _MotionSceneScope extends InheritedWidget {
  const _MotionSceneScope({required this.scene, required super.child});
  final _MotionSceneRegistrationState scene;

  @override
  bool updateShouldNotify(_MotionSceneScope oldWidget) =>
      scene != oldWidget.scene;
}

enum _MotionAnchorRole { content, avatar, composer }

class _MotionAnchor extends SingleChildRenderObjectWidget {
  const _MotionAnchor({
    required this.role,
    this.radius,
    this.glyphIdentity,
    required super.child,
  });
  final _MotionAnchorRole role;
  final BorderRadius? radius;
  final Object? glyphIdentity;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMotionAnchor(
    registry: _MotionHostScope.maybeOf(context),
    scene: context
        .dependOnInheritedWidgetOfExactType<_MotionSceneScope>()
        ?.scene,
    role: role,
    tickerEnabled: TickerMode.valuesOf(context).enabled,
    radius: radius,
    glyphIdentity: glyphIdentity,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMotionAnchor renderObject,
  ) {
    renderObject.update(
      registry: _MotionHostScope.maybeOf(context),
      scene: context
          .dependOnInheritedWidgetOfExactType<_MotionSceneScope>()
          ?.scene,
      tickerEnabled: TickerMode.valuesOf(context).enabled,
      radius: radius,
      glyphIdentity: glyphIdentity,
    );
  }
}

class _RenderMotionAnchor extends RenderRepaintBoundary {
  _RenderMotionAnchor({
    required this.registry,
    required this.scene,
    required this.role,
    required this.tickerEnabled,
    this.radius,
    this.glyphIdentity,
  });
  _MotionRegistry? registry;
  _MotionSceneRegistrationState? scene;
  final _MotionAnchorRole role;
  bool tickerEnabled;
  BorderRadius? radius;
  Object? glyphIdentity;
  bool _capturing = false;
  int _paintRevision = 0;
  int _sampledRevision = -1;

  void update({
    required _MotionRegistry? registry,
    required _MotionSceneRegistrationState? scene,
    required bool tickerEnabled,
    BorderRadius? radius,
    Object? glyphIdentity,
  }) {
    if (registry != this.registry) {
      this.registry?.removeAnchor(this);
      this.registry = registry;
      if (attached) registry?.anchors.add(this);
    }
    if (this.glyphIdentity != glyphIdentity) _sampledRevision = -1;
    this.scene = scene;
    this.tickerEnabled = tickerEnabled;
    this.radius = radius;
    this.glyphIdentity = glyphIdentity;
    registry?.schedule();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    registry?.anchors.add(this);
    registry?.schedule();
  }

  @override
  void detach() {
    registry?.removeAnchor(this);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    registry?.schedule();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (role == _MotionAnchorRole.avatar) {
      _paintRevision++;
      if (!(registry?.glyphs.containsKey(glyphIdentity) ?? true)) {
        registry?.schedule();
      }
    }
  }

  Future<void> sampleGlyph() async {
    final owner = registry;
    final identity = glyphIdentity;
    if (owner == null ||
        identity == null ||
        _capturing ||
        !attached ||
        layer == null ||
        !hasSize ||
        size.isEmpty ||
        _sampledRevision == _paintRevision ||
        owner.glyphs.containsKey(identity)) {
      return;
    }
    _capturing = true;
    _sampledRevision = _paintRevision;
    try {
      // Capture resolution is bounded by the mark, not window or display DPI.
      final image = await toImage(
        pixelRatio: 72 / math.max(size.width, size.height),
      );
      try {
        final glyph = await ConversationParticleGlyph.fromImage(image);
        if (glyph != null &&
            attached &&
            registry == owner &&
            glyphIdentity == identity) {
          owner.glyphs[identity] = glyph;
          owner.schedule();
        }
      } finally {
        image.dispose();
      }
    } finally {
      _capturing = false;
      if (_sampledRevision != _paintRevision) owner.schedule();
    }
  }
}

class _MotionPresentation {
  const _MotionPresentation({
    required this.identity,
    required this.assembled,
    required this.enabled,
    required this.anchors,
    required this.glyph,
    required this.onAssembled,
  });
  final Object identity;
  final bool assembled;
  final bool enabled;
  final ConversationParticleAnchors anchors;
  final ConversationParticleGlyph? glyph;
  final VoidCallback onAssembled;
}

class _MotionRegistry {
  final scenes = <_MotionSceneRegistrationState>[];
  final anchors = <_RenderMotionAnchor>{};
  final glyphs = <Object, ConversationParticleGlyph>{};
  final presentation = ValueNotifier<_MotionPresentation?>(null);
  late RenderObject? Function() surface;
  bool _scheduled = false;
  bool _disposed = false;

  void notifySubmit() {
    final scene = scenes
        .where(
          (scene) =>
              scene.mounted &&
              scene.widget.scene.visible &&
              !scene._completed &&
              scene._tickerEnabled,
        )
        .lastOrNull;
    if (scene == null ||
        !anchors.any(
          (anchor) =>
              anchor.scene == scene &&
              anchor.role == _MotionAnchorRole.content &&
              _onstage(anchor),
        )) {
      return;
    }
    scene.widget.scene.onSendInitiated?.call();
  }

  void removeScene(_MotionSceneRegistrationState scene) {
    scenes.remove(scene);
    schedule();
  }

  void removeAnchor(_RenderMotionAnchor anchor) {
    anchors.remove(anchor);
    schedule();
  }

  void schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) _measure();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Rect? _rect(
    _RenderMotionAnchor? anchor,
    RenderBox overlay, {
    bool clipped = false,
  }) {
    if (anchor == null ||
        !anchor.attached ||
        !anchor.hasSize ||
        anchor.size.isEmpty) {
      return null;
    }
    var rect = MatrixUtils.transformRect(
      anchor.getTransformTo(overlay),
      Offset.zero & anchor.size,
    );
    if (clipped) {
      RenderObject child = anchor;
      for (
        RenderObject? parent = child.parent;
        parent != null && child != overlay;
        parent = child.parent
      ) {
        final clip = parent.describeApproximatePaintClip(child);
        if (clip != null) {
          rect = rect.intersect(
            MatrixUtils.transformRect(parent.getTransformTo(overlay), clip),
          );
        }
        child = parent;
      }
    }
    return rect.isFinite && !rect.isEmpty ? rect : null;
  }

  bool _onstage(RenderObject object) {
    for (RenderObject? node = object; node != null; node = node.parent) {
      if (node is RenderOffstage && node.offstage) return false;
    }
    return true;
  }

  void _measure() {
    final overlay = surface();
    final scene = scenes
        .where(
          (scene) =>
              scene.mounted && scene.widget.scene.visible && !scene._completed,
        )
        .lastOrNull;
    if (overlay is! RenderBox || !overlay.hasSize || scene == null) {
      presentation.value = null;
      return;
    }
    _RenderMotionAnchor? content;
    _RenderMotionAnchor? avatar;
    _RenderMotionAnchor? composer;
    for (final anchor in anchors) {
      if (anchor.scene != scene &&
          !(anchor.role == _MotionAnchorRole.composer &&
              anchor.scene == null)) {
        continue;
      }
      switch (anchor.role) {
        case _MotionAnchorRole.content:
          content = anchor;
        case _MotionAnchorRole.avatar:
          avatar = anchor;
        case _MotionAnchorRole.composer:
          if (anchor.tickerEnabled && _onstage(anchor)) composer = anchor;
      }
    }
    final bounds = _rect(content, overlay, clipped: true);
    if (bounds == null) {
      presentation.value = null;
      return;
    }
    final diameter = bounds.shortestSide * 0.62;
    final glyph = glyphs[avatar?.glyphIdentity];
    final avatarRect = glyph == null ? null : _rect(avatar, overlay);
    if (avatar != null && glyph == null && _onstage(avatar)) {
      unawaited(avatar.sampleGlyph());
    }
    final composerRect = _rect(composer, overlay);
    RRect? outline;
    if (composer != null && composerRect != null) {
      final radius = composer.radius ?? BorderRadius.zero;
      final sx = composerRect.width / composer.size.width;
      final sy = composerRect.height / composer.size.height;
      Radius scaled(Radius r) => Radius.elliptical(r.x * sx, r.y * sy);
      outline = RRect.fromRectAndCorners(
        composerRect,
        topLeft: scaled(radius.topLeft),
        topRight: scaled(radius.topRight),
        bottomLeft: scaled(radius.bottomLeft),
        bottomRight: scaled(radius.bottomRight),
      ).scaleRadii();
    }
    final geometry = ConversationParticleAnchors(
      sphere: Rect.fromCenter(
        center: bounds.center,
        width: diameter,
        height: diameter,
      ),
      avatar: avatarRect,
      composer: outline,
    );
    final identity = scene.widget.scene.conversationKey;
    final assembled = scene.widget.scene.assembled;
    final enabled = scene._tickerEnabled && _onstage(content!);
    final previous = presentation.value;
    if (previous?.identity == identity &&
        previous?.assembled == assembled &&
        previous?.enabled == enabled &&
        previous?.anchors == geometry &&
        previous?.glyph == glyph) {
      return;
    }
    presentation.value = _MotionPresentation(
      identity: identity,
      assembled: assembled,
      enabled: enabled,
      anchors: geometry,
      glyph: glyph,
      onAssembled: () => scene._complete(identity),
    );
  }

  void dispose() {
    _disposed = true;
    scenes.clear();
    anchors.clear();
    glyphs.clear();
    presentation.dispose();
  }
}
