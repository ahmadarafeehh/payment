// lib/models/posted_result.dart
import 'dart:io';
import 'dart:typed_data';

/// Returned by AddPostScreen (via the camera route) after a successful upload,
/// so the profile can open the feed on the new post and show the share banner.
class PostedResult {
  /// Same columns the profile grid selects:
  /// postId, postUrl, description, datePublished, uid, viewers_count,
  /// video_edit_metadata
  final Map<String, dynamic> postRow;
  final bool isVideo;
  final Uint8List? imageBytes; // set for photo posts
  final File? videoFile; // set for video posts
  final String caption;

  const PostedResult({
    required this.postRow,
    required this.isVideo,
    this.imageBytes,
    this.videoFile,
    this.caption = '',
  });
}
