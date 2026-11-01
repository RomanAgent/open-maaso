import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';

/// Source selection is explicit intent, never an execution grant.
class HomeAppInvocationSheet extends StatefulWidget {
  const HomeAppInvocationSheet({
    super.key,
    required this.controller,
    required this.type,
  });
  final HomeController controller;
  final AppletCatalogType type;

  @override
  State<HomeAppInvocationSheet> createState() => _HomeAppInvocationSheetState();
}

class _HomeAppInvocationSheetState extends State<HomeAppInvocationSheet> {
  final _search = TextEditingController();
  late final Object _owner;
  Timer? _debounce;
  int _generation = 0;
  bool _public = false, _loading = false, _partial = false;
  String? _error, _cursor, _selecting;
  final _entries = <AppInvocationCatalogEntry>[];
  final _resolutions = <String, AppInvocationResolution>{};
  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  bool get _current =>
      mounted &&
      !widget.controller.isClosed &&
      identical(_owner, widget.controller.composerOwnerToken);
  String _key(AppInvocationCatalogEntry entry) =>
      '${entry.locator.origin.name}:${entry.locator.id}';

  @override
  void initState() {
    super.initState();
    _owner = widget.controller.composerOwnerToken;
    _load();
  }

  Future<void> _load({bool append = false}) async {
    final generation = ++_generation;
    final catalog = widget.controller.invocationCatalog;
    if (catalog == null) {
      setState(() {
        _loading = false;
        _error = 'unavailable';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _selecting = null;
    });
    try {
      final page = _public
          ? await catalog.searchPublic(
              type: widget.type,
              query: _search.text,
              cursor: append ? _cursor : null,
            )
          : await catalog.listPersonal(type: widget.type, query: _search.text);
      if (!_current ||
          generation != _generation ||
          !identical(catalog, widget.controller.invocationCatalog)) {
        return;
      }
      setState(() {
        if (!append) {
          _entries.clear();
          _resolutions.clear();
        }
        final keys = _entries.map(_key).toSet();
        _entries.addAll(page.entries.where((entry) => keys.add(_key(entry))));
        _cursor = page.nextCursor;
        _partial = page.sourceErrors.isNotEmpty;
      });
    } on Object {
      if (_current && generation == _generation) {
        setState(() => _error = 'load');
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _select(AppInvocationCatalogEntry entry) async {
    if (!_current || _selecting != null) {
      return;
    }
    final key = _key(entry);
    final generation = _generation;
    setState(() {
      _selecting = key;
      _error = null;
    });
    try {
      final result = await widget.controller.selectAppInvocation(
        entry,
        canContinue: () => _current && generation == _generation,
      );
      if (!_current || generation != _generation) {
        return;
      }
      if (result != null) {
        setState(() => _resolutions[key] = result);
        final chosen = widget.controller.selectedAppInvocation.value;
        if ((result.status ==
                    AppInvocationCompatibilityStatus.pendingVerification ||
                result.status == AppInvocationCompatibilityStatus.compatible) &&
            result.selection != null &&
            chosen != null &&
            chosen.identity.matches(result.selection!.identity) &&
            chosen.contractDigest == result.selection!.contractDigest) {
          if (!mounted) return;
          Navigator.of(context).pop();
        }
      }
    } on Object {
      if (_current && generation == _generation) {
        setState(() => _error = 'select');
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() => _selecting = null);
      }
    }
  }

  Future<void> _open(AppInvocationCatalogEntry entry) async {
    if (!_current || _selecting != null) return;
    final key = _key(entry);
    final generation = _generation;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    bool current() =>
        _current && generation == _generation && route?.isCurrent != false;
    setState(() {
      _selecting = key;
      _error = null;
    });
    try {
      final opened = await widget.controller.openAppInvocation(
        entry,
        canContinue: current,
      );
      if (!_current || generation != _generation) return;
      if (opened && route != null) {
        // The player is already above the sheet; remove this exact route rather
        // than popping the newly opened work. The composer draft stays intact.
        navigator.removeRoute(route);
      } else {
        setState(() => _error = 'open');
      }
    } on Object {
      if (_current && generation == _generation) {
        setState(() => _error = 'open');
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() => _selecting = null);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  String _status(AppInvocationResolution? resolution) =>
      switch (resolution?.status) {
        AppInvocationCompatibilityStatus.openOnly =>
          _zh
              ? '可直接打开 · 暂不支持 Agent 调用'
              : 'Open directly · Agent invocation unavailable',
        AppInvocationCompatibilityStatus.invalidContract =>
          _zh ? '调用说明不可用 · 可尝试打开' : 'Invalid call contract · try opening',
        AppInvocationCompatibilityStatus.pendingVerification =>
          _zh
              ? '来源引用 · 执行前验证能力'
              : 'Source reference · verified before execution',
        AppInvocationCompatibilityStatus.compatible =>
          _zh
              ? '可调用 · 执行仍需当前授权'
              : 'Compatible · execution requires current authorization',
        null => _zh ? '选择后检查操作说明' : 'Inspect operations when selected',
      };

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final media = MediaQuery.of(context);
    final available = math.max(
      80.0,
      media.size.height - media.viewInsets.bottom - media.viewPadding.top - 16,
    );
    final height = math.min(media.size.height * .76, available);
    final compact = height < 260;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Material(
        color: glass.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.type == AppletCatalogType.game
                                ? (_zh ? '选择小游戏' : 'Choose a game')
                                : (_zh ? '选择小程序' : 'Choose an applet'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          tooltip: _zh ? '关闭' : 'Close',
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(16, compact ? 8 : 4, 16, 8),
                  child: TextField(
                    key: const ValueKey('home-invocation-search'),
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    maxLength: 80,
                    decoration: InputDecoration(
                      hintText: _zh ? '搜索名称或用途' : 'Search names or purposes',
                      prefixIcon: const Icon(Icons.search),
                      counterText: '',
                      suffixIcon: compact
                          ? IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: _zh ? '关闭' : 'Close',
                              onPressed: () => Navigator.pop(context),
                            )
                          : null,
                    ),
                    onChanged: (_) {
                      _generation++;
                      _debounce?.cancel();
                      _debounce = Timer(
                        const Duration(milliseconds: 250),
                        _load,
                      );
                    },
                    onSubmitted: (_) {
                      _debounce?.cancel();
                      _load();
                    },
                  ),
                ),
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final public in [false, true])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(80, 48),
                                backgroundColor: _public == public
                                    ? glass.accentSoft
                                    : glass.muted,
                                foregroundColor: _public == public
                                    ? glass.accentText
                                    : glass.foregroundSecondary,
                              ),
                              onPressed: _selecting != null
                                  ? null
                                  : () {
                                      setState(() => _public = public);
                                      _load();
                                    },
                              child: Text(
                                public
                                    ? (_zh ? '发现' : 'Discover')
                                    : (_zh ? '我的' : 'Mine'),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_partial && !compact)
                  Text(
                    _zh
                        ? '部分来源暂时不可用'
                        : 'Some sources are temporarily unavailable',
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                    ),
                  ),
                Expanded(
                  child: _error != null && _entries.isEmpty
                      ? SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _error == 'unavailable'
                                    ? (_zh
                                          ? '当前账号的作品目录暂不可用'
                                          : 'The catalog is unavailable for this account')
                                    : (_zh
                                          ? '暂时未能加载作品'
                                          : 'Could not load works'),
                              ),
                              TextButton(
                                onPressed: _loading ? null : _load,
                                child: Text(_zh ? '重试' : 'Retry'),
                              ),
                            ],
                          ),
                        )
                      : _loading && _entries.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : _entries.isEmpty
                      ? Center(
                          child: Text(_zh ? '没有找到相关作品' : 'No matching works'),
                        )
                      : ListView.builder(
                          itemCount:
                              _entries.length + (_cursor != null ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == _entries.length) {
                              return TextButton(
                                onPressed: _loading
                                    ? null
                                    : () => _load(append: true),
                                child: Text(_zh ? '加载更多' : 'Load more'),
                              );
                            }
                            final entry = _entries[index], key = _key(entry);
                            final resolution = _resolutions[key];
                            final unavailable =
                                resolution?.status ==
                                    AppInvocationCompatibilityStatus.openOnly ||
                                resolution?.status ==
                                    AppInvocationCompatibilityStatus
                                        .invalidContract;
                            return ListTile(
                              key: ValueKey('home-invocation-$key'),
                              leading: Icon(
                                entry.type == AppletCatalogType.game
                                    ? Icons.sports_esports_outlined
                                    : Icons.apps_rounded,
                                color: glass.accentText,
                              ),
                              title: Text(entry.title),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (entry.summary.isNotEmpty)
                                    Text(
                                      entry.summary,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  Text(
                                    _status(resolution),
                                    style: TextStyle(
                                      color: glass.foregroundSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              trailing: _selecting == key
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : TextButton(
                                      key: ValueKey(
                                        'home-invocation-open-$key',
                                      ),
                                      style: TextButton.styleFrom(
                                        minimumSize: const Size(64, 48),
                                        foregroundColor: glass.accentText,
                                      ),
                                      onPressed: _selecting != null
                                          ? null
                                          : () => _open(entry),
                                      child: Text(_zh ? '打开' : 'Open'),
                                    ),
                              onTap: _selecting != null
                                  ? null
                                  : () => unavailable
                                        ? _open(entry)
                                        : _select(entry),
                            );
                          },
                        ),
                ),
                if (_error != null && _entries.isNotEmpty && !compact)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _zh
                          ? '此次操作未完成，可重试'
                          : 'The operation did not complete. Please retry.',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
