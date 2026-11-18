import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_expression_rig.dart';

const _skeleton = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 0 220 220">
  <defs><radialGradient id="e-x-head"/><linearGradient id="e-x-cup"/>
    <radialGradient id="e-x-arm"/></defs>
  <ellipse cx="100" cy="212" rx="64" ry="9" fill="url(#e-x-ground)"/>
  <g>
    <g transform="rotate(-6 100 150)"><circle cx="100" cy="90" r="66"
      fill="url(#e-x-head)"/></g>
    <g><path d="M40 142H160L148 201" fill="url(#e-x-cup)"/></g>
    <g><ellipse cx="69" cy="131" rx="20" fill="url(#e-x-arm)"/></g>
    <g><ellipse cx="131" cy="131" rx="20" fill="url(#e-x-arm)"/></g>
  </g>
  <path d="M10 10l4 4" stroke="#000"/>
</svg>
''';

/// celebrate.svg authors its raised arms before the body group.
const _reorderedSkeleton = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 220 220">
  <defs><radialGradient id="e-y-head"/><linearGradient id="e-y-cup"/>
    <radialGradient id="e-y-arm"/></defs>
  <ellipse cx="100" cy="212" rx="64" ry="9"/>
  <g>
    <g><circle cx="100" cy="90" r="66" fill="url(#e-y-head)"/></g>
    <g transform="translate(-31 -21)"><ellipse cx="69" cy="131" rx="20"
      fill="url(#e-y-arm)"/></g>
    <g transform="translate(31 -21)"><ellipse cx="131" cy="131" rx="20"
      fill="url(#e-y-arm)"/></g>
    <g><path d="M40 142H160" fill="url(#e-y-cup)"/></g>
  </g>
</svg>
''';

void main() {
  test(
    'parse splits the figure skeleton into semantic layers in paint order',
    () {
      final rig = MascotExpressionRig.parse(_skeleton)!;
      expect(rig.layers.map((layer) => layer.id).toList(), [
        MascotExpressionRig.partShadow,
        MascotExpressionRig.partHead,
        MascotExpressionRig.partBody,
        MascotExpressionRig.partArmLeft,
        MascotExpressionRig.partArmRight,
        MascotExpressionRig.partEffects,
      ]);
      expect(rig.viewBox, const Rect.fromLTWH(-10, 0, 220, 220));
      // Each layer re-declares the shared defs and the source viewBox.
      for (final layer in rig.layers) {
        expect(layer.svg, contains('e-x-head'));
        expect(layer.svg, contains('viewBox="-10 0 220 220"'));
      }
      expect(
        rig.layerFor(MascotExpressionRig.partHead).svg,
        contains('rotate(-6 100 150)'),
      );
      expect(
        rig.layerFor(MascotExpressionRig.partEffects).svg,
        contains('M10 10l4 4'),
      );
    },
  );

  test('parse classifies parts by content, not document order', () {
    final rig = MascotExpressionRig.parse(_reorderedSkeleton)!;
    expect(rig.layers[1].id, MascotExpressionRig.partHead);
    expect(rig.layers[2].id, MascotExpressionRig.partArmLeft);
    expect(rig.layers[3].id, MascotExpressionRig.partArmRight);
    expect(rig.layers[4].id, MascotExpressionRig.partBody);
  });

  test('parse returns null when the skeleton does not match', () {
    expect(MascotExpressionRig.parse('<svg viewBox="0 0 10 10"/>'), isNull);
    expect(MascotExpressionRig.parse('not xml'), isNull);
    expect(
      MascotExpressionRig.parse(
        '<svg viewBox="0 0 220 220"><ellipse/><g><g/></g></svg>',
      ),
      isNull,
    );
  });
}
