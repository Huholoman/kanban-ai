import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'item_style.dart';

/// A tag that opens an item's pull request in a new tab.
class PrLink extends StatelessWidget {
  const PrLink(this.url, {super.key});

  final String url;

  /// `PR #42` for GitHub / GitLab / Bitbucket style links, else `PR`.
  static String label(String url) {
    final number = RegExp(r'/(?:pull|pulls|merge_requests|pull-requests)/(\d+)').firstMatch(url)?.group(1);
    return number == null ? 'PR' : 'PR #$number';
  }

  /// Opens [url] in a new tab; null for anything but http(s) links.
  static VoidCallback? opener(String url) {
    final uri = Uri.tryParse(url);
    return uri == null ||
            !const {'http', 'https'}.contains(uri.scheme) // nothing like javascript:
        ? null
        : () => launchUrl(uri, mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: url,
      child: InkWell(
        key: ValueKey('pr-$url'),
        borderRadius: BorderRadius.circular(6),
        onTap: opener(url),
        child: Tag(label(url), icon: Icons.call_merge, color: Colors.purple.shade400),
      ),
    );
  }
}
