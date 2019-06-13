// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:split/split.dart' as split;

import '../framework/framework.dart';
import '../globals.dart';
import '../ui/analytics.dart' as ga;
import '../ui/analytics_platform.dart' as ga_platform;
import '../ui/elements.dart';
import '../ui/fake_flutter/dart_ui/dart_ui.dart';
import '../ui/icons.dart';
import '../ui/material_icons.dart';
import '../ui/primer.dart';
import '../ui/theme.dart';
import '../ui/ui_utils.dart';
import 'event_details.dart';
import 'frame_events_chart.dart';
import 'frames_bar_chart.dart';
import 'timeline_controller.dart';
import 'timeline_model.dart';
import 'timeline_protocol.dart';

// Light mode is Light Blue 50 palette and Dark mode is Blue 50 palette.
// https://material.io/design/color/the-color-system.html#tools-for-picking-colors.
const mainUiColorLight = Color(0xFF81D4FA); // Light Blue 50 - 200
const mainUiColorSelectedLight = Color(0xFFD4D7DA); // Lighter grey.

const mainGpuColorLight = Color(0xFF0288D1); // Light Blue 50 - 700
const mainGpuColorSelectedLight = Color(0xFFB5B5B5); // Darker grey.

const mainUiColorDark = Color(0xFF9EBEF9); // Blue 200 Material Dark
const mainUiColorSelectedDark = Colors.white;

const mainGpuColorDark = Color(0xFF1A73E8); // Blue 600 Material Dark
const mainGpuColorSelectedDark = Color(0xFFC9C9C9); // Grey.

const mainUiColor = ThemedColor(mainUiColorLight, mainUiColorDark);
const mainGpuColor = ThemedColor(mainGpuColorLight, mainGpuColorDark);

const Color selectedUiColor =
    ThemedColor(mainUiColorSelectedLight, mainUiColorSelectedDark);
const Color selectedGpuColor =
    ThemedColor(mainGpuColorSelectedLight, mainGpuColorSelectedDark);

// Light is Red @ .2 opacity, Dark is Red 200 Material Dark @ .2 opacity.
const Color jankGlowInside = ThemedColor(Color(0x66FF0000), Color(0x66F29C99));
// Light is Red @ .5 opacity, Dark is Red 600 Material Dark @ .6 opacity.
const Color jankGlowEdge = ThemedColor(Color(0x80FF0000), Color(0x99CE191C));

// Red 50 - 400 is light at 1/2 opacity, Dark Red 500 Material Dark.
const Color highwater16msColor = mainUiColorSelectedLight;

const Color hoverTextHighContrastColor = Colors.white;
const Color hoverTextColor = Colors.black;

// TODO(devoncarew): show the Skia picture (gpu drawing commands) for a frame

// TODO(devoncarew): show the list of widgets re-drawn during a frame

// TODO(devoncarew): display whether running in debug or profile

// TODO(devoncarew): Have a timeline view thumbnail overview.

// TODO(devoncarew): Switch to showing all timeline events, but highlighting the
// area associated with the selected frame.

const Icon _exportTimelineIcon = MaterialIcon(
  'file_download',
  defaultButtonIconColor,
  fontSize: 32,
  iconWidth: 18,
);

const Icon _clear = MaterialIcon('block', defaultButtonIconColor);

const Icon _exitIcon = MaterialIcon('clear', defaultButtonIconColor);

class TimelineScreen extends Screen {
  TimelineScreen({bool disabled, String disabledTooltip})
      : super(
          name: 'Timeline',
          id: timelineScreenId,
          iconClass: 'octicon-pulse',
          disabled: disabled,
          disabledTooltip: disabledTooltip,
        );

  TimelineController timelineController = TimelineController();

  FramesBarChart framesBarChart;

  FrameEventsChart frameEventsChart;

  EventDetails eventDetails;

  PButton pauseButton;

  PButton resumeButton;

  PButton clearButton;

  PButton exportButton;

  PButton exitOfflineModeButton;

  CoreElement upperButtonSection;

  CoreElement debugButtonSection;

  bool _manuallyPaused = false;

  split.Splitter splitter;

  bool splitterConfigured = false;

  @override
  CoreElement createContent(Framework framework) {
    ga_platform.setupDimensions();

    final CoreElement screenDiv = div()..layoutVertical();

    pauseButton = PButton.icon('Pause recording', FlutterIcons.pause_white_2x)
      ..small()
      ..primary()
      ..click(_pauseRecording);

    resumeButton =
        PButton.icon('Resume recording', FlutterIcons.resume_black_disabled_2x)
          ..small()
          ..clazz('margin-left')
          ..disabled = true
          ..click(_resumeRecording);

    exportButton = PButton.icon('', _exportTimelineIcon)
      ..small()
      ..clazz('margin-left')
      ..setAttribute('title', 'Export timeline')
      ..click(_exportTimeline);

    clearButton = PButton.icon('Clear', _clear)
      ..small()
      ..clazz('margin-left')
      ..setAttribute('title', 'Clear timeline')
      ..click(clearTimeline);

    exitOfflineModeButton = PButton.icon(
      'Exit offline mode',
      _exitIcon,
    )
      ..small()
      ..setAttribute('title', 'Exit offline mode to connect to a VM Service.')
      ..setAttribute('hidden', 'true')
      ..click(_exitOfflineMode);

    upperButtonSection = div(c: 'section')
      ..layoutHorizontal()
      ..add(<CoreElement>[
        div(c: 'btn-group')
          ..add([
            pauseButton,
            resumeButton,
          ]),
        clearButton,
        exitOfflineModeButton,
        div()..flex(),
        debugButtonSection = div(c: 'btn-group'),
        exportButton,
      ]);

    _maybeAddDebugButtons();

    screenDiv.add(<CoreElement>[
      upperButtonSection,
      div(c: 'section section-border')
        ..add(framesBarChart = FramesBarChart(timelineController)),
      div(c: 'section')
        ..layoutVertical()
        ..flex()
        ..add(<CoreElement>[
          frameEventsChart = FrameEventsChart(timelineController)
            ..attribute('hidden'),
          eventDetails = EventDetails(timelineController)..attribute('hidden'),
        ]),
    ]);

    _initListeners();

    maybeAddDebugMessage(framework, timelineScreenId);

    return screenDiv;
  }

  void _initListeners() {
    timelineController.onSelectedFrame.listen((_) => _configureSplitter());
    timelineController.onLoadOfflineData
        .listen((_) => frameEventsChart.attribute('hidden', true));
  }

  void _configureSplitter() {
    // Configure the flame chart / event details splitter if we haven't
    // already.
    if (!splitterConfigured) {
      splitter = split.flexSplit(
        [frameEventsChart.element, eventDetails.element],
        horizontal: false,
        gutterSize: defaultSplitterWidth,
        sizes: [75, 25],
        minSize: [50, 160],
      );
      splitterConfigured = true;
    }
  }

  void _destroySplitter() {
    if (splitterConfigured) {
      splitter.destroy();
      splitterConfigured = false;
    }
  }

  @override
  void entering() {
    _updateListeningState();
    _updateButtonStates();
  }

  @override
  void exiting() {
    _updateListeningState();
    _updateButtonStates();
  }

  void _exitOfflineMode() {
    // This needs to be called first because [framework.exitOfflineMode()] will
    // remove all elements from the dom if we are not connected to an app.
    // Performing operations from [_clearTimeline()] on elements that have been
    // removed will throw exceptions, so we need to maintain this order.
    clearTimeline();
    eventDetails.reset(hide: true);
    timelineController.exitOfflineMode();
    // This needs to be called before we update the button states because it
    // changes the value of [offlineMode], which the button states depend on.
    framework.exitOfflineMode();
    _updateButtonStates();
    _destroySplitter();
  }

  void _pauseRecording() {
    _manuallyPaused = true;
    timelineController.pause();
    ga.select(ga.timeline, ga.pause);
    _updateButtonStates();
    _updateListeningState();
  }

  void _resumeRecording() {
    _manuallyPaused = false;
    timelineController.resume();
    ga.select(ga.timeline, ga.resume);
    _updateButtonStates();
    _updateListeningState();
  }

  void _updateButtonStates() {
    pauseButton
      ..disabled = _manuallyPaused
      ..attribute('hidden', offlineMode);
    resumeButton
      ..disabled = !_manuallyPaused
      ..attribute('hidden', offlineMode);
    clearButton.attribute('hidden', offlineMode);
    exportButton.attribute('hidden', offlineMode);
    exitOfflineModeButton.attribute('hidden', !offlineMode);
  }

  void _updateListeningState() async {
    final bool shouldBeRunning = !_manuallyPaused && isCurrentScreen;
    final bool isRunning = !timelineController.paused;
    timelineController.timelineService.updateListeningState(
      shouldBeRunning: shouldBeRunning,
      isRunning: isRunning,
    );
  }

  void clearTimeline() {
    debugHandledTraceEvents.clear();
    debugFrameTracking.clear();
    timelineController.timelineData?.clear();
    framesBarChart.frameUIgraph.reset();
    frameEventsChart.attribute('hidden', true);
    eventDetails.reset(hide: true);
    _destroySplitter();
  }

  void _exportTimeline() {
    // TODO(kenzie): add analytics for this. It would be helpful to know how
    // complex the problems are that users are trying to solve.
    final String encodedTimelineData =
        jsonEncode(timelineController.timelineData.json);
    final now = DateTime.now();
    final timestamp =
        '${now.year}_${now.month}_${now.day}-${now.microsecondsSinceEpoch}';
    downloadFile(encodedTimelineData, 'timeline_$timestamp.json');
  }

  /// Adds a button to the timeline that will dump debug information to text
  /// files and download them. This will only appear if the [debugTimeline] flag
  /// is true.
  void _maybeAddDebugButtons() {
    if (debugTimeline) {
      debugButtonSection.add(PButton('Debug dump timeline')
        ..small()
        ..click(() {
          // Trace event json in the order we handled the events.
          final handledTraceEventsJson = {
            'traceEvents': debugHandledTraceEvents
          };
          downloadFile(
            jsonEncode(handledTraceEventsJson),
            'handled_trace_output.json',
          );

          // Significant events in the frame tracking process.
          downloadFile(
            debugFrameTracking.toString(),
            'frame_tracking_output.txt',
          );

          final timelineProtocol = timelineController.timelineProtocol;

          // Current status of our frame tracking elements (i.e. pendingEvents,
          // pendingFrames).
          final buf = StringBuffer();
          buf.writeln('Pending events: '
              '${timelineProtocol.pendingEvents.length}');
          for (TimelineEvent event in timelineProtocol.pendingEvents) {
            event.format(buf, '    ');
            buf.writeln();
          }
          buf.writeln('\nPending frames: '
              '${timelineProtocol.pendingFrames.length}');
          for (TimelineFrame frame in timelineProtocol.pendingFrames.values) {
            buf.writeln('${frame.toString()}');
          }
          if (timelineProtocol.currentEventNodes[TimelineEventType.ui.index] !=
              null) {
            buf.writeln('\nCurrent UI event node:');
            timelineProtocol.currentEventNodes[TimelineEventType.ui.index]
                .format(buf, '   ');
          }
          if (timelineProtocol.currentEventNodes[TimelineEventType.gpu.index] !=
              null) {
            buf.writeln('\n Current GPU event node:');
            timelineProtocol.currentEventNodes[TimelineEventType.gpu.index]
                .format(buf, '   ');
          }
          if (timelineProtocol.heaps[TimelineEventType.ui.index].isNotEmpty) {
            buf.writeln('\nUI heap');
            for (TraceEventWrapper wrapper in timelineProtocol
                .heaps[TimelineEventType.ui.index]
                .toList()) {
              buf.writeln(wrapper.event.json.toString());
            }
          }
          if (timelineProtocol.heaps[TimelineEventType.gpu.index].isNotEmpty) {
            buf.writeln('\nGPU heap');
            for (TraceEventWrapper wrapper in timelineProtocol
                .heaps[TimelineEventType.gpu.index]
                .toList()) {
              buf.writeln(wrapper.event.json.toString());
            }
          }
          downloadFile(buf.toString(), 'pending_frame_tracking_status.txt');
        }));
    }
  }
}
