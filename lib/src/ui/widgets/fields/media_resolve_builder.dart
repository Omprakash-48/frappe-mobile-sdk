import 'package:flutter/widgets.dart';

import '../../../services/media_resolver.dart';

/// Resolves an attach-field value to a local file path and rebuilds [builder]
/// with the result.
///
/// [builder] receives null while the resolve is in flight and whenever it yields
/// nothing (offline miss, unknown marker, failed fetch), so every caller must
/// have a sensible null branch — for the one current caller, an
/// `Image.network` of the server URL. Resolution is display-only and never
/// changes the stored value.
///
/// The future is MEMOISED per value. Starting it inside `build` would create a
/// new future on every rebuild, and each completion triggers another rebuild —
/// an infinite loop that re-reads the cache and can re-download forever.
///
/// ## Use this ONLY when the widget renders the file's CONTENT
///
/// Mounting this starts a resolve, and `MediaResolver.resolve` DOWNLOADS on a
/// cache miss — so building the widget fetches the bytes. That is right for
/// [ImageField], whose preview paints from the local file and would otherwise
/// pull the same bytes through `Image.network` anyway. It is wrong for anything
/// that only renders an affordance: [AttachField] used this for its view
/// **button** and thereby downloaded every attachment on a form the moment the
/// form appeared, up to 25 MB each, before the user asked for any of them. It
/// now resolves inside the button's tap handler instead
/// (`_AttachViewButton.resolver`), which keeps the memoisation property above
/// because a tap is not a rebuild.
///
/// So: content on screen → eager resolve here. A button that opens the file
/// later → resolve on tap, not here.
class MediaResolveBuilder extends StatefulWidget {
  final ResolveMediaFn? resolver;
  final String? value;
  final Map<int, String>? pendingPaths;
  final Widget Function(BuildContext context, String? localPath) builder;

  const MediaResolveBuilder({
    super.key,
    required this.resolver,
    required this.value,
    required this.pendingPaths,
    required this.builder,
  });

  @override
  State<MediaResolveBuilder> createState() => _MediaResolveBuilderState();
}

class _MediaResolveBuilderState extends State<MediaResolveBuilder> {
  Future<String?>? _resolved;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MediaResolveBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value ||
        oldWidget.resolver != widget.resolver) {
      _start();
    }
  }

  void _start() {
    final r = widget.resolver;
    final v = widget.value;
    if (r == null || v == null || v.trim().isEmpty) {
      _resolved = null;
      return;
    }
    _resolved = r(v, pendingPaths: widget.pendingPaths);
  }

  @override
  Widget build(BuildContext context) {
    final future = _resolved;
    // No resolver wired, or nothing to resolve: the caller's null branch is the
    // pre-existing behaviour, so hosts that opt out lose nothing.
    if (future == null) return widget.builder(context, null);
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final local = snapshot.data;
        return widget.builder(
          context,
          (local != null && local.isNotEmpty) ? local : null,
        );
      },
    );
  }
}
