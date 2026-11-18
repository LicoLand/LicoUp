import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:xml/xml.dart';

/// One independently transformable slice of an expression SVG. Each bundled
/// expression is drawn as a flat stack of authored layers — the same file is
/// also exported as the static PNG used for the reduced-motion path — so the
/// layers compose back to the identical illustration when every transform is
/// the identity.
final class MascotExpressionRigLayer {
  const MascotExpressionRigLayer(this.id, this.svg);

  final String id;
  final String svg;
}

/// The Live2D-style part binding for one bundled expression.
///
/// The authored SVGs share a fixed skeleton: a root ground-shadow ellipse,
/// one figure group whose direct groups are the head, the body and the two
/// arms (document order varies — a raised arm is authored before the body —
/// so parts are classified by their gradient ids), then any trailing
/// root-level effect elements (confetti, speech dots, "zzz"). Splitting at
/// those boundaries gives semantic layers that can be rotated, scaled and
/// translated independently around anatomical pivots, which is what makes
/// the idle read as rigged instead of a single image wobbling.
final class MascotExpressionRig {
  const MascotExpressionRig._({required this.viewBox, required this.layers});

  /// The SVG viewBox of the source document; part pivots are authored in this
  /// coordinate space and scaled to the rendered extent by the painter.
  final Rect viewBox;

  /// Paint order preserved from the source document so the identity pose
  /// composites to the same pixels as the flattened PNG.
  final List<MascotExpressionRigLayer> layers;

  static const String partShadow = 'shadow';
  static const String partHead = 'head';
  static const String partBody = 'body';
  static const String partArmLeft = 'armLeft';
  static const String partArmRight = 'armRight';
  static const String partEffects = 'effects';

  MascotExpressionRigLayer layerFor(String part) =>
      layers.firstWhere((layer) => layer.id == part);

  static const String _assetRoot = 'assets/mascot/expressions/svg';

  static final Map<String, Future<MascotExpressionRig?>> _cache = {};

  /// Loads and splits the SVG source for [expressionId]. Returns null when the
  /// asset is missing or does not match the expected skeleton — callers fall
  /// back to the static PNG path in that case.
  static Future<MascotExpressionRig?> load(String expressionId) {
    return _cache.putIfAbsent(expressionId, () async {
      try {
        final source = await rootBundle.loadString(
          '$_assetRoot/$expressionId.svg',
        );
        return parse(source);
      } on Object {
        return null;
      }
    });
  }

  /// Splits [source] into rigged layers. Visible for testing.
  @visibleForTesting
  static MascotExpressionRig? parse(String source) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlException {
      return null;
    }
    final root = document.rootElement;
    final viewBoxAttr = root.getAttribute('viewBox');
    if (viewBoxAttr == null) return null;
    final parts = viewBoxAttr
        .trim()
        .split(RegExp(r'[,\s]+'))
        .map(double.tryParse)
        .toList();
    if (parts.length != 4 || parts.any((v) => v == null)) return null;
    final viewBox = Rect.fromLTWH(parts[0]!, parts[1]!, parts[2]!, parts[3]!);

    final defs = root.getElement('defs');
    final elements = root.childElements
        .where((e) => e.name.local != 'defs')
        .toList();
    if (elements.isEmpty) return null;
    final first = elements.first;
    if (first.name.local != 'ellipse') return null;
    final figureIndex = elements.indexWhere((e) => e.name.local == 'g');
    if (figureIndex < 0) return null;
    final figure = elements[figureIndex];
    final limbs = figure.childElements
        .where((e) => e.name.local == 'g')
        .toList();
    // The figure's groups are head, body and the two arms, but their order
    // varies between expressions (a raised arm is authored before the body,
    // etc.) so parts are classified by the gradient ids they draw with. An
    // arm's side comes from its shadow ellipse center: cx < 100 is left.
    final limbsByPart = <String, XmlElement>{};
    final classifiedLimbs = <XmlElement, String>{};
    for (final limb in limbs) {
      final markup = limb.toXmlString();
      String kind;
      if (markup.contains('-head')) {
        kind = partHead;
      } else if (markup.contains('-cup')) {
        kind = partBody;
      } else {
        final cx =
            double.tryParse(
              RegExp(r'cx="([\d.]+)"').firstMatch(markup)?.group(1) ?? '',
            ) ??
            100;
        kind = cx < 100 ? partArmLeft : partArmRight;
      }
      // A part kind already claimed means the skeleton does not match the
      // expected shape; the caller falls back to the static PNG path.
      if (classifiedLimbs.containsValue(kind)) return null;
      classifiedLimbs[limb] = kind;
      limbsByPart[kind] = limb;
    }
    for (final part in [partHead, partBody, partArmLeft, partArmRight]) {
      if (!limbsByPart.containsKey(part)) return null;
    }
    final extras = elements.skip(figureIndex + 1).toList();

    String layerXml(List<XmlElement> members) {
      final buffer = StringBuffer()
        ..write(
          '<svg xmlns="http://www.w3.org/2000/svg" '
          'viewBox="$viewBoxAttr">',
        );
      if (defs != null) buffer.write(defs.toXmlString());
      for (final member in members) {
        buffer.write(member.toXmlString());
      }
      buffer.write('</svg>');
      return buffer.toString();
    }

    return MascotExpressionRig._(
      viewBox: viewBox,
      layers: [
        MascotExpressionRigLayer(partShadow, layerXml([first])),
        for (final limb in limbs)
          MascotExpressionRigLayer(classifiedLimbs[limb]!, layerXml([limb])),
        if (extras.isNotEmpty)
          MascotExpressionRigLayer(partEffects, layerXml(extras)),
      ],
    );
  }
}
