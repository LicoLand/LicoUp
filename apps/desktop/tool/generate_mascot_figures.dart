// Generates `assets/mascot/figures/svg/<id>.svg` from
// `assets/mascot/avatars/svg/<id>.svg` by removing only the painted
// background: the full-canvas <rect>, the background glow <ellipse>, and
// a leading background <g> (stars) when present — everything before the
// character group (the first <g transform=...>). <defs> and the
// character group stay byte-identical.
import 'dart:io';

void main() {
  final outDir = Directory('assets/mascot/figures/svg')
    ..createSync(recursive: true);
  for (final entity in Directory(
    'assets/mascot/avatars/svg',
  ).listSync().whereType<File>()) {
    final name = entity.uri.pathSegments.last;
    final svg = entity.readAsStringSync();
    // The character group is the first <g transform=...>; keep everything
    // from the <svg> tag through the first </defs>, then the character
    // group onward — dropping all top-level elements in between.
    final defsEnd = svg.indexOf('</defs>');
    final charStart = svg.indexOf(RegExp(r'<g\s+transform'));
    if (defsEnd < 0 || charStart < 0 || charStart < defsEnd) {
      stderr.writeln('$name: layout not recognised, skipped');
      continue;
    }
    final head = svg.substring(0, defsEnd + '</defs>'.length);
    final figure = '$head\n  ${svg.substring(charStart).trimLeft()}';
    File('${outDir.path}/$name').writeAsStringSync(figure);
  }
  stdout.writeln('generated ${outDir.listSync().length} figures');
}
