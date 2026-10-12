import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fnesemu_core/app_api.dart';

import '../../styles.dart';
import 'debug_controller.dart';
import 'disasm.dart';
import 'mem.dart';
import 'video.dart';

class DebugPane extends StatefulWidget {
  final Debugger debugger;
  final CoreController? controller;
  final VoidCallback? onClose;
  const DebugPane(
      {super.key, required this.debugger, this.controller, this.onClose});
  @override
  State<DebugPane> createState() => _DebugPaneState();
}

class _DebugPaneState extends State<DebugPane> {
  double _scale = 1;
  VideoHover? _hover;
  bool? _magnifierRight, _magnifierBottom;
  void _hoverChanged(VideoHover value) => setState(() => _hover = value);
  void _hoverExit() {
    if (_hover != null) {
      setState(() {
        _hover = null;
        _magnifierRight = _magnifierBottom = null;
      });
    }
  }

  Widget _magnified(Widget child, DebugState state) =>
      LayoutBuilder(builder: (context, bounds) {
        final box =
            _hover == null ? null : context.findRenderObject() as RenderBox?;
        final point = _hover != null && box != null
            ? box.globalToLocal(_hover!.global)
            : null;
        final show = state.view != DebugView.cpu &&
            point != null &&
            (Offset.zero & Size(bounds.maxWidth, bounds.maxHeight))
                .contains(point);
        if (show) {
          final cursorRight = point.dx >= bounds.maxWidth / 2;
          _magnifierBottom ??= point.dy < bounds.maxHeight / 2;
          _magnifierRight ??= !cursorRight;
          if (_magnifierRight == cursorRight) _magnifierRight = !cursorRight;
        }
        final origin = box?.localToGlobal(Offset.zero) ?? Offset.zero;
        final window = MediaQuery.sizeOf(context);
        final desiredLeft = _magnifierRight == false
            ? 6.0
            : bounds.maxWidth - VideoMagnifier.extent - 6;
        final desiredTop = _magnifierBottom == false
            ? 6.0
            : bounds.maxHeight - VideoMagnifier.extent - 6;
        final left = (origin.dx + desiredLeft).clamp(
                6.0, math.max(6.0, window.width - VideoMagnifier.extent - 6)) -
            origin.dx;
        final top = (origin.dy + desiredTop).clamp(
                6.0, math.max(6.0, window.height - VideoMagnifier.extent - 6)) -
            origin.dy;
        return NotificationListener<ScrollNotification>(
            onNotification: (_) {
              if (_hover != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _hover = _hover?.refresh());
                });
              }
              return false;
            },
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(child: child),
              if (show)
                Positioned(
                    left: left,
                    top: top,
                    child: VideoMagnifier(
                        key: const ValueKey('video-magnifier'),
                        hover: _hover!)),
            ]));
      });
  @override
  Widget build(BuildContext context) => StreamBuilder<DebugState>(
      stream: widget.debugger.debugStream,
      initialData: widget.debugger.state,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        if (!state.showDebugView || widget.debugger.cpuInfos.isEmpty) {
          return const SizedBox.shrink();
        }
        final views = <(DebugView, LayerView?, String)>[
          (DebugView.cpu, null, 'CPU'),
          (DebugView.layers, LayerView.screen, 'ViewPort'),
          (DebugView.layers, LayerView.map, 'Screen'),
          if (state.hasPatterns) (DebugView.patterns, null, 'Patterns'),
        ];
        final selected = views
            .indexWhere((tab) =>
                tab.$1 == state.view &&
                (tab.$2 == null || tab.$2 == state.layerView))
            .clamp(0, views.length - 1);
        return Theme(
            data: debugTheme(Theme.of(context)),
            child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: DefaultTabController(
                    key: ValueKey((views.length, selected)),
                    length: views.length,
                    initialIndex: selected,
                    child: _magnified(
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _header(views),
                              if (state.view == DebugView.cpu) _cpuTabs(state),
                              if (state.view == DebugView.cpu &&
                                  widget.controller != null)
                                Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: DebugController(
                                        controller: widget.controller!)),
                              if (state.view != DebugView.cpu)
                                _videoControls(state),
                              Expanded(
                                  child: SingleChildScrollView(
                                      child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: state.view == DebugView.cpu
                                              ? _cpu(state)
                                              : DebugVideoImages(
                                                  state: state,
                                                  scale: _scale,
                                                  onHover: _hoverChanged,
                                                  onExit: _hoverExit)))),
                            ]),
                        state))));
      });
  Widget _header(List<(DebugView, LayerView?, String)> views) =>
      LayoutBuilder(builder: (context, bounds) {
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
                width: widget.controller == null
                    ? bounds.maxWidth
                    : math.max(320, bounds.maxWidth),
                child: Row(children: [
                  if (widget.controller != null)
                    DebugExecutionControls(debugger: widget.debugger),
                  Expanded(
                      child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                    onTap: (index) {
                      final tab = views[index];
                      if (tab.$2 != null) {
                        widget.debugger.setLayerView(tab.$2!);
                      }
                      widget.debugger.selectView(tab.$1);
                    },
                    tabs: [
                      for (final tab in views) Tab(text: tab.$3, height: 32),
                    ],
                  )),
                  IconButton(
                      key: const ValueKey('debug-close'),
                      tooltip: 'Close debugger',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onClose ??
                          () => widget.debugger.setDebugView(false),
                      icon: const Icon(Icons.close)),
                ])));
      });

  Widget _cpuTabs(DebugState state) {
    final cpus = widget.debugger.cpuInfos;
    final selected = cpus.indexWhere((cpu) => cpu.no == state.targetCpuNo);
    return DefaultTabController(
        key: ValueKey((cpus.map((cpu) => cpu.no).join(','), selected)),
        length: cpus.length,
        initialIndex: selected,
        child: TabBar(
            key: const ValueKey('debug-cpu-tabs'),
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsets.symmetric(horizontal: 6),
            onTap: (index) => widget.debugger.selectCpu(cpus[index].no),
            tabs: [for (final cpu in cpus) Tab(text: cpu.name, height: 28)]));
  }

  Widget _cpu(DebugState state) {
    final cpu = widget.debugger.cpuInfo(state.targetCpuNo);
    return Padding(
        padding: const EdgeInsets.all(2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DebugDisasm(
                key: ValueKey(('disasm', cpu.no)),
                debugger: widget.debugger,
                cpuNo: cpu.no,
                forwardLines: 48,
                backwardLines: 6,
                width: 300,
                addrBits: cpu.pcBitWidth),
            const SizedBox(width: 4),
            SizedBox(
                width: 396,
                child: MemPane(
                    key: ValueKey(('memory', cpu.no)),
                    debugger: widget.debugger,
                    cpuNo: cpu.no)),
          ]),
        ]));
  }

  Widget _videoControls(DebugState state) {
    final debugger = widget.debugger;
    Widget option(String label, bool value, void Function(bool) change) =>
        FilterChip(
            label: Text(label),
            selected: value,
            onSelected: change,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap);
    return Padding(
        padding: const EdgeInsets.all(2),
        child: Wrap(
            spacing: 3,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              option('Live rendering', state.videoLive, debugger.setVideoLive),
              if (state.view == DebugView.patterns) ...[
                SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 8, label: Text('8×8')),
                      ButtonSegment(value: 16, label: Text('16×16')),
                      ButtonSegment(value: 32, label: Text('32×32')),
                    ],
                    selected: {
                      state.patternBlockSize
                    },
                    onSelectionChanged: (values) =>
                        debugger.setPatternBlockSize(values.single)),
                IconButton(
                    tooltip: 'Previous palette',
                    onPressed: debugger.selectPreviousPalette,
                    icon: const Icon(Icons.chevron_left)),
                const Text('Palette'),
                IconButton(
                    tooltip: 'Next palette',
                    onPressed: debugger.selectNextPalette,
                    icon: const Icon(Icons.chevron_right)),
              ],
              option('BG Color', state.alternativeBackground,
                  debugger.setAlternativeBackground),
              if (state.videoPanels
                  .any((p) => p.raster.patterns.isNotEmpty)) ...[
                option('No.', state.patternNumbers,
                    debugger.setPatternNumbersVisible),
                option('Bounds', state.patternBounds,
                    debugger.setPatternBoundsVisible),
              ],
              if (state.videoPanels.any((p) => p.raster.viewports.isNotEmpty))
                option('Viewport', state.viewportBounds,
                    debugger.setViewportBoundsVisible),
              SizedBox(
                  width: 170,
                  height: 28,
                  child: Row(children: [
                    Expanded(
                        child: Slider(
                            key: const ValueKey('debug-video-scale'),
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            value: _scale,
                            min: 0.5,
                            max: 4,
                            divisions: 14,
                            label: '$_scale×',
                            semanticFormatterCallback: (value) => '$value×',
                            onChanged: (value) =>
                                setState(() => _scale = value))),
                    SizedBox(
                        width: 40, child: Text('$_scale×', style: debugStyle)),
                  ])),
              IconButton(
                  tooltip: 'Refresh video',
                  onPressed: debugger.refreshVideo,
                  icon: const Icon(Icons.refresh)),
            ]));
  }
}
