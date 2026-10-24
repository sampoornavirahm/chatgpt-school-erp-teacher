import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Uri? schoolMeetingUri(Object? value) {
  if (value is! String || value.trim().isEmpty || value.trim().length > 2048) {
    return null;
  }
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

class SchoolMeetingLinkButton extends StatelessWidget {
  const SchoolMeetingLinkButton({super.key, required this.link});

  final Object? link;

  @override
  Widget build(BuildContext context) {
    if (schoolMeetingUri(link) == null) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: TextButton.icon(
        icon: const Icon(Icons.video_call_outlined),
        label: const Text('Open class'),
        onPressed: () async {
          final uri = schoolMeetingUri(link);
          if (uri == null) return;
          var opened = false;
          try {
            opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {
            // The device may not have a handler for the supplied meeting provider.
          }
          if (!context.mounted || opened) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open the online class link.'),
            ),
          );
        },
      ),
    );
  }
}
