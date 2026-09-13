import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/steel_ball_waiting_indicator.dart';

const _output = String.fromEnvironment('LICO_MOTION_EVIDENCE_DIR');
const _size = Size(1040, 700);
const _anchors = ConversationParticleAnchors(
  sphere: Rect.fromLTWH(450, 150, 360, 360),
  avatar: Rect.fromLTWH(48, 112, 40, 40),
  composer: RRect.fromLTRBXY(48, 566, 992, 652, 24, 24),
);

/// Opt-in synthetic evidence, exported by Flutter itself. No user screenshots,
/// account content or backend state are read. This is not a timing regression
/// gate: headless debug measurements do not establish production GPU budgets.
void main() {
  testWidgets(
    'export continuous curling shell in both themes at Retina scale',
    (tester) async {
      await tester.runAsync(() async {
        final directory = Directory('$_output/globe')
          ..createSync(recursive: true);
        await (FontLoader('Geist Sans')
              ..addFont(rootBundle.load('assets/fonts/GeistSans-Regular.ttf')))
            .load();
        const size = Size(1040, 600);
        const darkAnchors = ConversationParticleAnchors(
          sphere: Rect.fromLTWH(30, 76, 460, 460),
        );
        const lightAnchors = ConversationParticleAnchors(
          sphere: Rect.fromLTWH(550, 76, 460, 460),
        );
        final geometry = ConversationParticleGeometry();
        final clock = ValueNotifier<double>(0);
        final dark = ConversationParticlePainter(
          geometry: geometry,
          anchors: darkAnchors,
          clock: clock,
          color: const Color(0xffe1e5e9),
        );
        final light = ConversationParticlePainter(
          geometry: geometry,
          anchors: lightAnchors,
          clock: clock,
          color: const Color(0xff3e4650),
        );
        final cpu = <int>[];
        final cold = Stopwatch()..start();
        geometry.writeFrame(0, darkAnchors);
        cold.stop();
        for (var frame = 0; frame < 720; frame++) {
          final stopwatch = Stopwatch()..start();
          geometry.writeFrame(frame / 60, darkAnchors);
          stopwatch.stop();
          cpu.add(stopwatch.elapsedMicroseconds);
        }
        for (var frame = 0; frame <= 360; frame++) {
          clock.value = frame / 30;
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)..scale(2);
          canvas.drawColor(const Color(0xff090b0d), BlendMode.src);
          canvas.drawRect(
            const Rect.fromLTWH(520, 0, 520, 600),
            Paint()..color = const Color(0xfff4f5f6),
          );
          _text(
            canvas,
            'CONTINUOUS CURL',
            const Offset(32, 30),
            const Color(0xff9aa5ad),
            12,
          );
          _text(
            canvas,
            '${clock.value.toStringAsFixed(2)} s',
            const Offset(930, 30),
            const Color(0xff64707b),
            12,
          );
          dark.paint(canvas, size);
          light.paint(canvas, size);
          final picture = recorder.endRecording();
          final image = await picture.toImage(2080, 1200);
          await _writePng(
            image,
            '${directory.path}/globe-${frame.toString().padLeft(3, '0')}.png',
          );
          image.dispose();
          picture.dispose();
        }
        final report = {
          'scope':
              'Actual Flutter painter at 2x; synthetic empty shell. '
              'CPU samples run at 60 Hz in headless debug, not production GPU.',
          'particles': geometry.count,
          'seconds': 12,
          'cold_geometry_us': cold.elapsedMicroseconds,
          'continuous_60hz_geometry_cpu_us': _summary(cpu),
          'persistent_geometry_bytes': geometry.allocatedBytes,
        };
        File(
          '${directory.path}/performance.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
        File('${directory.path}/index.html').writeAsStringSync(
          '''<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Curling shell · Flutter 2x</title>
<style>body{margin:0;background:#090b0d;color:#dde2e7;font:14px system-ui;display:grid;place-items:center}img{width:min(100%,1040px)}nav{display:flex;gap:16px;align-items:center;padding:18px}input{width:520px}button{padding:8px 18px}output{width:80px}</style>
<img id="frame" src="globe-000.png" alt="Two themes of the same continuously curling sphere">
<nav><button id="play">Pause</button><input id="time" type="range" min="0" max="360" value="0"><output id="label">0.00 s</output></nav>
<script>
let i=0,playing=true;
const frame=document.querySelector('#frame'),time=document.querySelector('#time'),label=document.querySelector('#label'),play=document.querySelector('#play');
function show(){frame.src='globe-'+String(i).padStart(3,'0')+'.png';time.value=i;label.value=(i/30).toFixed(2)+' s'}
time.oninput=()=>{i=+time.value;playing=false;play.textContent='Play';show()};
play.onclick=()=>{playing=!playing;play.textContent=playing?'Pause':'Play'};
setInterval(()=>{if(playing){i=(i+1)%361;show()}},1000/30);
</script></html>''',
        );
        clock.dispose();
      });
    },
    skip: _output.isEmpty,
  );

  testWidgets(
    'export particle and steel frames with synthetic anchors',
    (tester) async {
      await tester.runAsync(() async {
        final directory = Directory(_output)..createSync(recursive: true);
        await (FontLoader('Geist Sans')
              ..addFont(rootBundle.load('assets/fonts/GeistSans-Regular.ttf')))
            .load();
        final markRecorder = ui.PictureRecorder();
        _mark(
          Canvas(markRecorder),
          const Rect.fromLTWH(0, 0, 64, 64),
          Colors.white,
        );
        final markPicture = markRecorder.endRecording();
        final mark = await markPicture.toImage(64, 64);
        final glyph = await ConversationParticleGlyph.fromImage(mark);
        mark.dispose();
        markPicture.dispose();
        final geometry = ConversationParticleGeometry();
        geometry.assemble(
          seconds: 9.5,
          duration: 2,
          anchors: _anchors,
          glyph: glyph,
        );
        final clock = ValueNotifier<double>(8);
        final painter = ConversationParticlePainter(
          geometry: geometry,
          anchors: _anchors,
          clock: clock,
          color: const Color(0xffe1e5e9),
        );
        final frameMicros = <int>[];
        final rasterMicros = <int>[];
        final frames = <ui.Image>[];
        final selected = {0, 36, 48, 60, 72, 80, 88, 96};
        for (var frame = 0; frame <= 96; frame++) {
          final seconds = frame / 24;
          clock.value = 8 + seconds;
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          _surface(canvas, seconds, dark: true);
          final stopwatch = Stopwatch()..start();
          painter.paint(canvas, _size);
          stopwatch.stop();
          frameMicros.add(stopwatch.elapsedMicroseconds);
          if (seconds >= 1.5 && seconds < 1.75) {
            _steel(canvas, seconds, dark: true);
          }
          final picture = recorder.endRecording();
          stopwatch
            ..reset()
            ..start();
          final image = await picture.toImage(
            _size.width.toInt(),
            _size.height.toInt(),
          );
          stopwatch.stop();
          rasterMicros.add(stopwatch.elapsedMicroseconds);
          await _writePng(
            image,
            '${directory.path}/frame-${frame.toString().padLeft(3, '0')}.png',
          );
          if (selected.contains(frame)) {
            frames.add(image);
          } else {
            image.dispose();
          }
          picture.dispose();
        }
        final sheetRecorder = ui.PictureRecorder();
        final sheetCanvas = Canvas(sheetRecorder);
        for (var i = 0; i < frames.length; i++) {
          sheetCanvas.drawImageRect(
            frames[i],
            Offset.zero & _size,
            Rect.fromLTWH((i % 2) * 520, (i ~/ 2) * 350, 520, 350),
            Paint(),
          );
        }
        final sheetPicture = sheetRecorder.endRecording();
        final sheet = await sheetPicture.toImage(1040, 1400);
        await _writePng(sheet, '${directory.path}/contact-sheet.png');
        sheet.dispose();
        sheetPicture.dispose();
        for (final image in frames) {
          image.dispose();
        }

        // The same geometry, API and canvas painter are also exercised in light.
        clock.value = 8;
        final lightRecorder = ui.PictureRecorder();
        final lightCanvas = Canvas(lightRecorder);
        _surface(lightCanvas, 0, dark: false);
        ConversationParticlePainter(
          geometry: geometry,
          anchors: _anchors,
          clock: clock,
          color: const Color(0xff3e4650),
        ).paint(lightCanvas, _size);
        _steel(lightCanvas, 0.4, dark: false);
        final lightPicture = lightRecorder.endRecording();
        final lightImage = await lightPicture.toImage(1040, 700);
        await _writePng(lightImage, '${directory.path}/light.png');
        lightImage.dispose();
        lightPicture.dispose();

        final steelFrames = <ui.Image>[];
        for (var frame = 0; frame <= 48; frame++) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..drawColor(const Color(0xff090b0d), BlendMode.src);
          _text(
            canvas,
            'ELASTIC MOMENTUM',
            const Offset(24, 18),
            const Color(0xff9aa5ad),
            11,
          );
          canvas.save();
          canvas.translate(20, 49);
          canvas.scale(2.5);
          SteelBallWaitingPainter(
            phase: AlwaysStoppedAnimation(frame / 48),
            silver: const Color(0xffcbd3db),
            shadow: const Color(0xff050608),
            rail: const Color(0xff89939c),
          ).paint(canvas, const Size(92.5, 50));
          canvas.restore();
          final picture = recorder.endRecording();
          final image = await picture.toImage(280, 180);
          await _writePng(
            image,
            '${directory.path}/steel-${frame.toString().padLeft(3, '0')}.png',
          );
          if (frame % 8 == 0 && frame < 48) {
            steelFrames.add(image);
          } else {
            image.dispose();
          }
          picture.dispose();
        }
        final steelSheetRecorder = ui.PictureRecorder();
        final steelSheetCanvas = Canvas(steelSheetRecorder);
        for (var i = 0; i < steelFrames.length; i++) {
          steelSheetCanvas.drawImage(
            steelFrames[i],
            Offset((i % 3) * 280, (i ~/ 3) * 180),
            Paint(),
          );
        }
        final steelSheetPicture = steelSheetRecorder.endRecording();
        final steelSheet = await steelSheetPicture.toImage(840, 360);
        await _writePng(
          steelSheet,
          '${directory.path}/steel-contact-sheet.png',
        );
        steelSheet.dispose();
        steelSheetPicture.dispose();
        for (final image in steelFrames) {
          image.dispose();
        }

        // Warmed, isolated CPU geometry samples supplement full canvas recording.
        final cpu = <int>[];
        for (var frame = 0; frame < 420; frame++) {
          final stopwatch = Stopwatch()..start();
          geometry.writeFrame(8 + (frame % 84) / 24, _anchors);
          stopwatch.stop();
          if (frame >= 120) cpu.add(stopwatch.elapsedMicroseconds);
        }
        final report = {
          'scope':
              'Synthetic headless Flutter debug evidence; not production GPU performance.',
          'particles': geometry.count,
          'fps': 24,
          'frames': 97,
          'geometry_cpu_us': _summary(cpu),
          'geometry_and_canvas_recording_us': _summary(frameMicros),
          'headless_picture_to_image_us': _summary(rasterMicros),
          'persistent_typed_particle_buffers_bytes':
              geometry.allocatedBytes + geometry.count * 9 + 48 * 4 + 49 * 4,
        };
        File(
          '${directory.path}/performance.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
        File('${directory.path}/index.html').writeAsStringSync(
          '''<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Conversation motion · synthetic evidence</title>
<style>body{margin:0;background:#090b0d;color:#dde2e7;font:14px system-ui;display:grid;place-items:center}img{width:min(100%,1040px)}nav{display:flex;gap:16px;align-items:center;padding:18px}input{width:520px}button{padding:8px 18px}output{width:80px}</style>
<img id="frame" src="frame-000.png" alt="Synthetic particle transition frame">
<nav><button id="play">Pause</button><input id="time" type="range" min="0" max="96" value="0"><output id="label">0.00 s</output></nav>
<p>Drag to inspect each original Flutter-rendered frame. Idle → send at 1.50 s → first text at 1.75 s → settled at 3.50 s.</p>
<img id="steel" src="steel-000.png" style="width:280px" alt="Three elastic steel spheres between visible end stops">
<script>
let i=0,s=0,playing=true;
const frame=document.querySelector('#frame'),time=document.querySelector('#time'),label=document.querySelector('#label'),play=document.querySelector('#play'),steel=document.querySelector('#steel');
function show(){frame.src='frame-'+String(i).padStart(3,'0')+'.png';time.value=i;label.value=(i/24).toFixed(2)+' s'}
time.oninput=()=>{i=+time.value;playing=false;play.textContent='Play';show()};
play.onclick=()=>{playing=!playing;play.textContent=playing?'Pause':'Play'};
setInterval(()=>{if(playing){i=(i+1)%97;show()}},1000/24);
setInterval(()=>{if(playing){s=(s+1)%48;steel.src='steel-'+String(s).padStart(3,'0')+'.png'}},1000/30);
</script></html>''',
        );
        clock.dispose();
        expect(glyph, isNotNull);
      });
    },
    skip: _output.isEmpty,
  );
}

Map<String, num> _summary(List<int> samples) {
  final sorted = [...samples]..sort();
  return {
    'samples': samples.length,
    'median': sorted[sorted.length ~/ 2],
    'p95': sorted[(sorted.length * 0.95).floor()],
    'max': sorted.last,
  };
}

Future<void> _writePng(ui.Image image, String path) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(
    data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

void _mark(Canvas canvas, Rect bounds, Color color) {
  final path = Path()
    ..moveTo(
      bounds.left + bounds.width * 0.5,
      bounds.top + bounds.height * 0.16,
    )
    ..lineTo(
      bounds.left + bounds.width * 0.77,
      bounds.top + bounds.height * 0.77,
    )
    ..lineTo(
      bounds.left + bounds.width * 0.60,
      bounds.top + bounds.height * 0.67,
    )
    ..lineTo(
      bounds.left + bounds.width * 0.5,
      bounds.top + bounds.height * 0.39,
    )
    ..lineTo(
      bounds.left + bounds.width * 0.40,
      bounds.top + bounds.height * 0.67,
    )
    ..lineTo(
      bounds.left + bounds.width * 0.23,
      bounds.top + bounds.height * 0.77,
    )
    ..close();
  canvas.drawPath(path, Paint()..color = color);
}

void _text(
  Canvas canvas,
  String text,
  Offset position,
  Color color,
  double size,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontFamily: 'Geist Sans', fontSize: size, color: color),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, position);
}

void _surface(Canvas canvas, double seconds, {required bool dark}) {
  final background = dark ? const Color(0xff090b0d) : const Color(0xfff4f5f6);
  final silver = dark ? const Color(0xffdce1e6) : const Color(0xff3e4650);
  final muted = dark ? const Color(0xff6f767d) : const Color(0xff727b84);
  final line = dark ? const Color(0xff262c32) : const Color(0xffd1d6db);
  canvas.drawColor(background, BlendMode.src);
  _text(canvas, 'NEW CONVERSATION', const Offset(48, 42), muted, 12);
  _text(
    canvas,
    '${seconds.toStringAsFixed(2)} s',
    const Offset(925, 42),
    muted,
    12,
  );
  canvas.drawLine(
    const Offset(48, 82),
    const Offset(992, 82),
    Paint()..color = line,
  );
  canvas.drawCircle(
    _anchors.avatar!.center,
    20,
    Paint()..color = dark ? const Color(0xff171b20) : const Color(0xffe3e7eb),
  );
  _mark(canvas, _anchors.avatar!, silver);
  _text(canvas, 'Agent', const Offset(106, 122), silver, 14);
  if (seconds >= 1.75) {
    _text(
      canvas,
      'The first response is already here.',
      const Offset(106, 174),
      silver,
      15,
    );
  }
  canvas.drawRRect(
    _anchors.composer!,
    Paint()..color = dark ? const Color(0xff12161a) : Colors.white,
  );
  canvas.drawRRect(
    _anchors.composer!,
    Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1,
  );
  _text(canvas, 'Message your Agent', const Offset(72, 596), muted, 15);
  canvas.drawCircle(
    const Offset(958, 609),
    17,
    Paint()..color = const Color(0xffe9ff65),
  );
  final arrow = Path()
    ..moveTo(952, 610)
    ..lineTo(958, 604)
    ..lineTo(964, 610)
    ..moveTo(958, 604)
    ..lineTo(958, 615);
  canvas.drawPath(
    arrow,
    Paint()
      ..color = const Color(0xff15191d)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );
}

void _steel(Canvas canvas, double seconds, {required bool dark}) {
  canvas.save();
  canvas.translate(110, 207);
  SteelBallWaitingPainter(
    phase: AlwaysStoppedAnimation(seconds / 1.6),
    silver: dark ? const Color(0xffcbd3db) : const Color(0xff6a7784),
    shadow: dark ? const Color(0xff050608) : const Color(0xff5d6670),
    rail: dark ? const Color(0xff89939c) : const Color(0xff73808b),
  ).paint(canvas, const Size(74, 40));
  canvas.restore();
}
