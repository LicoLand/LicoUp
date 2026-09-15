import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import '../support/canonical_group/paged_conversation_native.dart';
import 'flutter_adapter.dart';
import 'model.dart';

final class UiInteractionRun {
  UiInteractionRun(this.model, {required this.performance});
  final UiInteractionModel model;
  final bool performance;
  static const seed = int.fromEnvironment('LICO_UI_SEED', defaultValue: 915);
  static const randomSteps = int.fromEnvironment(
    'LICO_UI_STEPS',
    defaultValue: 40,
  );
  static const selectedMachine = String.fromEnvironment('LICO_UI_MACHINE');
  static const replay = String.fromEnvironment('LICO_UI_REPLAY');
  bool selects(UiMachine machine) =>
      (selectedMachine.isEmpty || selectedMachine == machine.id) &&
      (!performance || machine.presentation.endsWith('-wide'));
  final List<Map<String, Object?>> results = [];
  final Map<String, bool> completed = {};
  final List<FrameTiming> _frames = [];
  final Map<String, Object?> inventory = {};
  final Map<String, Object?> failures = {};

  Map<String, Object?> report() => {
    'seed': seed,
    'randomSteps': randomSteps,
    'mode': performance ? 'profile' : 'widget-functional',
    'measurement': performance
        ? 'Pointer dispatch to the expected rendered UI; includes test-driver overhead. Frame timings come from the engine, grouped by transition frame timestamps.'
        : 'Virtual-clock widget test: functional coverage only, no FPS or latency claim.',
    'results': results,
    'visibleControls': inventory,
    'failures': failures,
    'completedMachines': completed,
    'declaredTransitions': {
      for (final machine in model.machines)
        if (selects(machine)) machine.id: machine.transitions.length,
    },
  };

  Future<void> exercise(WidgetTester tester, UiMachine machine) async {
    completed[machine.id] = false;
    final wide = machine.presentation.endsWith('-wide');
    final size = wide
        ? const Size(1280, 900)
        : machine.presentation.endsWith('-medium')
        ? const Size(820, 1100)
        : const Size(430, 900);
    await tester.binding.setSurfaceSize(size);
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse(machine.presentation.split('-').first),
      surface: wide
          ? LayoutRuntimeSurface.desktop
          : LayoutRuntimeSurface.mobile,
      destination: ClientSection.agents,
      size: size,
      brightness: Brightness.light,
      conversationNativePort: machine.populated
          ? PagedConversationNative()
          : null,
    );
    final adapter = FlutterInteractionAdapter(
      tester,
      machine,
      nativeAgentId: fixture.controller.selectedConversationAgentId,
    );
    // Keep the displayed composer directory synthetic as well as the data.
    fixture.controller.newConversationWorkingDirectories = {
      fixture.controller.selectedConversationAgentId: '/test-workspace',
    };
    if (performance) tester.binding.addTimingsCallback(_frames.addAll);
    final sequence = <String>[];
    try {
      final app = fixture.buildApp(
        semanticsKey: const ValueKey('ui-interaction-root'),
        repaintBoundaryKey: const ValueKey('ui-interaction-view'),
        disableAnimations: false,
      );
      // The production composition installs disk-backed ports. This fixture
      // substitutes only persistence, before any real widgets are mounted.
      final dockStore = _MemoryDockStore();
      final featureStore = _MemoryFeatureStore();
      ClientPlatformPorts.dockLayoutStore = () => dockStore;
      ClientPlatformPorts.featureOrderStore = () => featureStore;
      await tester.pumpWidget(app);
      // Start from the actual visible chat page. Setup also uses real clicks.
      for (var i = 0; i < 4; i += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      for (final action in machine.setup) {
        await adapter.act(action);
        await tester.pump(const Duration(milliseconds: 300));
      }
      await adapter.waitFor(machine.initial);
      final random = UiRandom(seed);
      final planned = replay.isEmpty
          ? machine.coverageWalk()
          : <UiTransition>[];
      final replayActions = replay.isEmpty ? <String>[] : replay.split(',');
      var state = machine.initial;
      final count = replay.isEmpty
          ? planned.length + randomSteps
          : replayActions.length;
      for (var step = 0; step < count; step += 1) {
        final outgoing = machine.outgoing[state] ?? <UiTransition>[];
        inventory.putIfAbsent(
          '${machine.id}/$state',
          () => adapter.inventory(
            model.actions.keys,
            outgoing.map((edge) => edge.action).toSet(),
          ),
        );
        // Missing declared controls fail; filtering them away would hide bugs.
        final available = outgoing
            .where((edge) => adapter.available(edge.action))
            .toList();
        expect(
          available.length,
          outgoing.length,
          reason:
              'Declared actions must be visible in ${machine.states[state]}: ${outgoing.where((e) => !adapter.available(e.action)).map((e) => e.action).join(', ')}',
        );
        final edge = replay.isNotEmpty
            ? outgoing.singleWhere((edge) => edge.action == replayActions[step])
            : step < planned.length
            ? planned[step]
            : available[random.choose(available.length)];
        expect(
          adapter.at(edge.from),
          isTrue,
          reason: 'Start state: ${machine.states[edge.from]}',
        );
        final startFrame =
            tester.binding.currentSystemFrameTimeStamp.inMicroseconds;
        final watch = Stopwatch()..start();
        sequence.add(edge.action);
        final result = <String, Object?>{
          'machine': machine.id,
          'presentation': machine.presentation,
          'transition': edge.id,
          'step': step + 1,
          'phase': replay.isNotEmpty
              ? 'replay'
              : step < planned.length
              ? 'coverage'
              : 'random',
          'actionId': edge.action,
          'from': machine.states[edge.from],
          'action': model.actionLabel(edge.action),
          'to': machine.states[edge.to],
          'passed': false,
        };
        results.add(result);
        try {
          await adapter.act(edge.action);
          await adapter.waitFor(edge.to);
          watch.stop();
          result['passed'] = true;
          state = edge.to;
          if (performance) {
            result['responseMs'] = watch.elapsedMicroseconds / 1000;
          }
        } catch (_) {
          result['replay'] = [...sequence];
          if (performance) {
            result['failedAfterMs'] = watch.elapsedMicroseconds / 1000;
          }
          rethrow;
        } finally {
          watch.stop();
          if (performance) {
            result['_startFrame'] = startFrame;
            result['_endFrame'] =
                tester.binding.currentSystemFrameTimeStamp.inMicroseconds;
          }
        }
      }
      final ending = machine.outgoing[state] ?? <UiTransition>[];
      expect(
        ending.every((edge) => adapter.available(edge.action)),
        isTrue,
        reason: 'The final state must retain its declared controls',
      );
      completed[machine.id] = true;
    } catch (error) {
      failures[machine.id] = {
        'kind': error.runtimeType.toString(),
        'replay': [...sequence],
      };
      rethrow;
    } finally {
      if (performance) {
        // Engine timing callbacks are batched. Flush once per complete graph,
        // not before/after every click; never invent zeroes for missing frames.
        await Future<void>.delayed(const Duration(seconds: 2));
        tester.binding.removeTimingsCallback(_frames.addAll);
        final refreshRate = tester.view.display.refreshRate;
        for (final result in results.where(
          (row) => row['machine'] == machine.id,
        )) {
          final start = result.remove('_startFrame') as int?;
          final end = result.remove('_endFrame') as int?;
          final frames = start == null || end == null
              ? <FrameTiming>[]
              : _frames.where((frame) {
                  // Scheduler frame timestamps identify vsync, not build start.
                  // Using buildStart would shift the last frame into the next action.
                  final timestamp = frame.timestampInMicroseconds(
                    FramePhase.vsyncStart,
                  );
                  return timestamp > start && timestamp <= end;
                }).toList();
          result['frameCount'] = frames.length;
          if (frames.isEmpty) {
            result['frames'] = 'unavailable';
            continue;
          }
          double maxOf(Duration Function(FrameTiming) value) => frames
              .map((f) => value(f).inMicroseconds / 1000)
              .reduce((a, b) => a > b ? a : b);
          result['maxUiFrameMs'] = maxOf((frame) => frame.buildDuration);
          result['maxRasterFrameMs'] = maxOf((frame) => frame.rasterDuration);
          if (refreshRate > 0) {
            final budgetUs = 1000000 / refreshRate;
            result['refreshHz'] = refreshRate;
            result['overBudgetFrames'] = frames
                .where(
                  (frame) =>
                      frame.buildDuration.inMicroseconds > budgetUs ||
                      frame.rasterDuration.inMicroseconds > budgetUs,
                )
                .length;
          }
          if (frames.length > 1) {
            final times =
                frames
                    .map(
                      (f) => f.timestampInMicroseconds(FramePhase.buildStart),
                    )
                    .toList()
                  ..sort();
            final span = times.last - times.first;
            result['renderedFramesPerSecond'] = span > 0
                ? (times.length - 1) * 1000000 / span
                : null;
            var longestGap = 0;
            for (var i = 1; i < times.length; i += 1) {
              final gap = times[i] - times[i - 1];
              if (gap > longestGap) longestGap = gap;
            }
            result['longestFrameGapMs'] = longestGap / 1000;
          }
        }
        _frames.clear();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.closeComposition);
      fixture.dispose();
      await tester.binding.setSurfaceSize(null);
    }
  }
}

final class _MemoryDockStore extends DesktopDockLayoutStore {
  DesktopDockLayoutSnapshot value = const DesktopDockLayoutSnapshot(
    entries: [],
  );
  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) async => value;
  @override
  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {
    value = snapshot;
  }
}

final class _MemoryFeatureStore extends DashboardFeatureOrderStore {
  List<String> value = DashboardFeatureOrder.defaultOrder;
  @override
  Future<List<String>> load(Object portableData) async => value;
  @override
  Future<void> save(Object portableData, List<String> order) async {
    value = List.of(order);
  }
}
