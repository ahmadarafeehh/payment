import 'dart:typed_data';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class StorageMethods {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final SupabaseClient _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  // ===========================================================================
  // ERROR LOGGING HELPER
  // ===========================================================================
  Future<void> _logPostError({
    required String operationType,
    String? userId,
    String? mediaUrl,
    required dynamic error,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _supabase.from('posts_errors').insert({
        'user_id': userId,
        'operation_type': operationType,
        'media_url': mediaUrl,
        'error_message': error.toString(),
        'stack_trace': error is Error ? error.stackTrace?.toString() : null,
        'additional_data': additionalData,
      });
    } catch (_) {
      // Silently ignore logging failures
    }
  }

  // Helper to get the current user ID from Supabase session
  String? _getCurrentUserId() {
    final session = _supabase.auth.currentSession;
    return session?.user.id;
  }

  // ===========================================================================
  // URL VERIFICATION
  // Performs an HTTP HEAD request on the returned CDN URL to confirm the file
  // is actually accessible. getPublicUrl() is pure string construction — it
  // does not verify the file exists. This catches silent upload failures before
  // the post row is inserted.
  // ===========================================================================
  Future<void> _verifyUrlAccessible(String publicUrl) async {
    try {
      final headResponse = await http
          .head(Uri.parse(publicUrl))
          .timeout(const Duration(seconds: 8));

      if (headResponse.statusCode != 200) {
        throw Exception(
          'File uploaded but not accessible at CDN URL '
          '(HTTP ${headResponse.statusCode}). '
          'Upload may have failed silently.',
        );
      }
    } on http.ClientException catch (e) {
      throw Exception('URL verification network error: $e');
    } on SocketException catch (e) {
      throw Exception('URL verification socket error: $e');
    }
    // TimeoutException propagates up as-is — caller catches it
  }

  // ===========================================================================
  // IMAGE METHODS - SUPABASE ONLY
  // ===========================================================================

  // Upload image to Supabase Storage
  Future<String> uploadImageToSupabase(Uint8List file, String fileName,
      {bool useUserFolder = true}) async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in to upload image');
      }

      String extension = fileName.split('.').last.toLowerCase();

      if (!['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension)) {
        throw Exception(
            'Invalid image file type. Supported: jpg, jpeg, png, gif, webp, bmp');
      }

      final String uniqueFileName = '${const Uuid().v1()}.$extension';

      final String filePath =
          useUserFolder ? '$userId/$uniqueFileName' : uniqueFileName;

      final tempFile = await _createTempFile(uniqueFileName, file);

      await _supabase.storage.from('Images').upload(filePath, tempFile,
          fileOptions: FileOptions(
            contentType: _getMimeType(extension),
            upsert: true,
          ));

      await tempFile.delete();

      final String publicUrl =
          _supabase.storage.from('Images').getPublicUrl(filePath);

      // Verify the file is actually accessible on the CDN before returning.
      // This prevents inserting a post row with a URL that returns 404.
      await _verifyUrlAccessible(publicUrl);

      return publicUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'upload_image',
        userId: userId,
        mediaUrl: fileName,
        error: e,
        additionalData: {'useUserFolder': useUserFolder},
      );
      throw Exception('Failed to upload image to Supabase: $e');
    }
  }

  // Upload image file to Supabase (from File object)
  Future<String> uploadImageFileToSupabase(File imageFile, String fileName,
      {bool useUserFolder = true}) async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in to upload image');
      }

      String extension = fileName.split('.').last.toLowerCase();

      if (!['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(extension)) {
        throw Exception('Invalid image file type');
      }

      final String uniqueFileName = '${const Uuid().v1()}.$extension';

      final String filePath =
          useUserFolder ? '$userId/$uniqueFileName' : uniqueFileName;

      await _supabase.storage.from('Images').upload(filePath, imageFile,
          fileOptions: FileOptions(
            contentType: _getMimeType(extension),
            upsert: true,
          ));

      final String publicUrl =
          _supabase.storage.from('Images').getPublicUrl(filePath);

      // Verify the file is actually accessible on the CDN before returning.
      await _verifyUrlAccessible(publicUrl);

      return publicUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'upload_image_file',
        userId: userId,
        mediaUrl: fileName,
        error: e,
        additionalData: {'useUserFolder': useUserFolder},
      );
      throw Exception('Failed to upload image file to Supabase: $e');
    }
  }

  // Pick image from gallery and upload to Supabase
  Future<String?> pickAndUploadImageToSupabase() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1080,
      );

      if (pickedFile == null) return null;

      final File imageFile = File(pickedFile.path);
      final fileName = pickedFile.name;

      final url = await uploadImageFileToSupabase(
        imageFile,
        fileName,
        useUserFolder: true,
      );

      return url;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'pick_and_upload_image',
        userId: userId,
        error: e,
      );
      throw Exception('Failed to pick and upload image: $e');
    }
  }

  // Capture image from camera and upload to Supabase
  Future<String?> captureAndUploadImageToSupabase() async {
    try {
      final XFile? capturedFile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1080,
      );

      if (capturedFile == null) return null;

      final File imageFile = File(capturedFile.path);
      final fileName = capturedFile.name;

      final url = await uploadImageFileToSupabase(
        imageFile,
        fileName,
        useUserFolder: true,
      );

      return url;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'capture_and_upload_image',
        userId: userId,
        error: e,
      );
      throw Exception('Failed to capture and upload image: $e');
    }
  }

  // ===========================================================================
  // IMAGE DELETION METHODS
  // ===========================================================================

  Future<void> deleteImageFromSupabase(String filePath) async {
    try {
      await _supabase.storage.from('Images').remove([filePath]);
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'delete_image_from_supabase',
        userId: userId,
        mediaUrl: filePath,
        error: e,
      );
      await _deleteViaRestApi('Images', filePath);
    }
  }

  Future<void> deleteImage(String imageUrl) async {
    try {
      if (imageUrl.isEmpty || imageUrl == 'default') return;

      if (_isSupabaseUrl(imageUrl)) {
        await deleteImageByUrl(imageUrl);
      } else if (_isFirebaseUrl(imageUrl)) {
        // Firebase URL — migration to Supabase required
      } else if (_isGooglePhoto(imageUrl)) {
        return;
      } else {
        throw Exception('Unknown storage provider for URL: $imageUrl');
      }
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'delete_image',
        userId: userId,
        mediaUrl: imageUrl,
        error: e,
      );
      throw Exception('Failed to delete image: $e');
    }
  }

  Future<void> deleteImageByUrl(String imageUrl) async {
    try {
      final pattern = RegExp(r'storage/v1/object/public/Images/(.+)');
      final match = pattern.firstMatch(imageUrl);

      if (match == null || match.groupCount < 1) {
        throw Exception('Invalid Supabase image URL');
      }

      final filePath = match.group(1)!;
      await deleteImageFromSupabase(filePath);
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'delete_image_by_url',
        userId: userId,
        mediaUrl: imageUrl,
        error: e,
      );
      throw Exception('Failed to delete image by URL: $e');
    }
  }

  // ===========================================================================
  // PROFILE IMAGE METHODS
  // ===========================================================================

  Future<void> updateUserProfileImage(String imageUrl) async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in');
      }

      await _supabase
          .from('users')
          .update({'photoUrl': imageUrl}).eq('uid', userId);
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'update_user_profile_image',
        userId: userId,
        mediaUrl: imageUrl,
        error: e,
      );
      throw Exception('Failed to update user profile image: $e');
    }
  }

  Future<String> uploadProfileImage(
      Uint8List imageBytes, String fileName) async {
    try {
      final imageUrl = await uploadImageToSupabase(
        imageBytes,
        fileName,
        useUserFolder: true,
      );

      await updateUserProfileImage(imageUrl);

      return imageUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'upload_profile_image',
        userId: userId,
        mediaUrl: fileName,
        error: e,
      );
      throw Exception('Failed to upload and set profile image: $e');
    }
  }

  Future<String> uploadProfileImageFile(File imageFile, String fileName) async {
    try {
      final imageUrl = await uploadImageFileToSupabase(
        imageFile,
        fileName,
        useUserFolder: true,
      );

      await updateUserProfileImage(imageUrl);

      return imageUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'upload_profile_image_file',
        userId: userId,
        mediaUrl: fileName,
        error: e,
      );
      throw Exception('Failed to upload and set profile image: $e');
    }
  }

  // ===========================================================================
  // IMAGE LISTING & INFO METHODS
  // ===========================================================================

  Future<List<String>> listUserImages() async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in');
      }

      final response =
          await _supabase.storage.from('Images').list(path: userId);

      final List<String> imageUrls = [];
      for (final file in response) {
        final publicUrl = _supabase.storage
            .from('Images')
            .getPublicUrl('$userId/${file.name}');
        imageUrls.add(publicUrl);
      }

      return imageUrls;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'list_user_images',
        userId: userId,
        error: e,
      );
      throw Exception('Failed to list user images: $e');
    }
  }

  Future<bool> imageExists(String filePath) async {
    try {
      final response = await _supabase.storage
          .from('Images')
          .list(path: filePath.contains('/') ? filePath.split('/').first : '');

      final fileName = filePath.split('/').last;
      return response.any((file) => file.name == fileName);
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'image_exists',
        userId: userId,
        mediaUrl: filePath,
        error: e,
      );
      return false;
    }
  }

  Future<Map<String, dynamic>> getImageInfo(String filePath) async {
    try {
      final response = await _supabase.storage
          .from('Images')
          .list(path: filePath.contains('/') ? filePath.split('/').first : '');

      final file = response.firstWhere(
          (f) => f.name == filePath.split('/').last,
          orElse: () => throw Exception('File not found'));

      return {
        'name': file.name,
        'size': file.metadata?['size'] ?? 0,
        'mimeType': file.metadata?['mimetype'] ?? 'unknown',
        'createdAt': file.createdAt,
        'updatedAt': file.updatedAt,
      };
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'get_image_info',
        userId: userId,
        mediaUrl: filePath,
        error: e,
      );
      throw Exception('Failed to get image info: $e');
    }
  }

  // ===========================================================================
  // VIDEO METHODS - SUPABASE ONLY
  // ===========================================================================

  Future<String> uploadVideoToSupabase(Uint8List file, String fileName,
      {bool useUserFolder = true}) async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in to upload video');
      }

      String extension = fileName.split('.').last.toLowerCase();

      if (!['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv'].contains(extension)) {
        throw Exception(
            'Invalid video file type. Supported: mp4, mov, avi, mkv, webm, flv');
      }

      final String uniqueFileName = '${const Uuid().v1()}.$extension';

      final String filePath =
          useUserFolder ? '$userId/$uniqueFileName' : uniqueFileName;

      final tempFile = await _createTempFile(uniqueFileName, file);

      await _supabase.storage.from('videos').upload(filePath, tempFile);

      await tempFile.delete();

      final String publicUrl =
          _supabase.storage.from('videos').getPublicUrl(filePath);

      // Verify the file is actually accessible on the CDN before returning.
      await _verifyUrlAccessible(publicUrl);

      return publicUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'upload_video',
        userId: userId,
        mediaUrl: fileName,
        error: e,
        additionalData: {'useUserFolder': useUserFolder},
      );
      throw Exception('Failed to upload video to Supabase: $e');
    }
  }

  // Upload video from File
  Future<String> uploadVideoFileToSupabase(File videoFile, String fileName,
      {bool useUserFolder = true}) async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in to upload video');
      }

      String extension = fileName.split('.').last.toLowerCase();

      if (!['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv'].contains(extension)) {
        throw Exception('Invalid video file type');
      }

      final String uniqueFileName = '${const Uuid().v1()}.$extension';

      final String filePath =
          useUserFolder ? '$userId/$uniqueFileName' : uniqueFileName;

      await _supabase.storage.from('videos').upload(filePath, videoFile);

      final String publicUrl =
          _supabase.storage.from('videos').getPublicUrl(filePath);

      // Verify the file is actually accessible on the CDN before returning.
      await _verifyUrlAccessible(publicUrl);

      return publicUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'upload_video_file',
        userId: userId,
        mediaUrl: fileName,
        error: e,
        additionalData: {'useUserFolder': useUserFolder},
      );
      throw Exception('Failed to upload video file to Supabase: $e');
    }
  }

  // Pick video from gallery and upload to Supabase
  Future<String?> pickAndUploadVideoToSupabase() async {
    try {
      final XFile? pickedFile = await _picker.pickVideo(
        source: ImageSource.gallery,
      );

      if (pickedFile == null) return null;

      final File videoFile = File(pickedFile.path);
      final fileName = pickedFile.name;

      final url = await uploadVideoFileToSupabase(
        videoFile,
        fileName,
        useUserFolder: true,
      );

      return url;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'pick_and_upload_video',
        userId: userId,
        error: e,
      );
      throw Exception('Failed to pick and upload video: $e');
    }
  }

  // MAIN DELETE VIDEO METHOD
  Future<void> deleteVideoFromSupabase(
      String bucketName, String filePath) async {
    try {
      try {
        final response =
            await _supabase.storage.from(bucketName).remove([filePath]);

        if (response.isNotEmpty) {
          await _verifyDeletion(bucketName, filePath);
          return;
        }
      } catch (e) {
        // Continue to next method
      }

      await _deleteViaRestApi(bucketName, filePath);
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'delete_video',
        userId: userId,
        mediaUrl: filePath,
        error: e,
        additionalData: {'bucketName': bucketName},
      );
      throw Exception('Failed to delete video: $e');
    }
  }

  Future<String> getSignedUrlForVideo(String fileName,
      {int expiresIn = 60}) async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in to get signed URL');
      }

      String actualFileName = fileName;
      if (fileName.contains('/')) {
        actualFileName = fileName.split('/').last;
      }

      final String userFolderPath = '$userId/$actualFileName';

      final String signedUrl = await _supabase.storage
          .from('videos')
          .createSignedUrl(userFolderPath, expiresIn);
      return signedUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'get_signed_url',
        userId: userId,
        mediaUrl: fileName,
        error: e,
        additionalData: {'expiresIn': expiresIn},
      );
      throw Exception('Failed to get signed URL: $e');
    }
  }

  Future<List<String>> listUserVideos() async {
    try {
      final userId = _getCurrentUserId();
      if (userId == null) {
        throw Exception('User must be logged in');
      }

      final response =
          await _supabase.storage.from('videos').list(path: userId);

      final List<String> videoFiles = [];
      for (final file in response) {
        final fileName = file.name;
        if (fileName != null && fileName is String && _isVideoFile(fileName)) {
          videoFiles.add(fileName);
        }
      }
      return videoFiles;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'list_user_videos',
        userId: userId,
        error: e,
      );
      throw Exception('Failed to list user videos: $e');
    }
  }

  Future<Map<String, dynamic>> getVideoInfo(String filePath) async {
    try {
      final response = await _supabase.storage
          .from('videos')
          .list(path: filePath.contains('/') ? filePath.split('/').first : '');

      final file = response.firstWhere(
          (f) => f.name == filePath.split('/').last,
          orElse: () => throw Exception('File not found'));

      return {
        'name': file.name,
        'size': file.metadata?['size'] ?? 0,
        'mimeType': file.metadata?['mimetype'] ?? 'unknown',
        'createdAt': file.createdAt,
        'updatedAt': file.updatedAt,
      };
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'get_video_info',
        userId: userId,
        mediaUrl: filePath,
        error: e,
      );
      throw Exception('Failed to get video info: $e');
    }
  }

  // ===========================================================================
  // HELPER METHODS
  // ===========================================================================

  Future<File> _createTempFile(String fileName, Uint8List data) async {
    try {
      final systemTemp = Directory.systemTemp;
      if (await systemTemp.exists()) {
        final tempFile = File('${systemTemp.path}/$fileName');
        await tempFile.writeAsBytes(data);
        return tempFile;
      }
    } catch (e) {
      // Fall through
    }

    try {
      final currentDir = Directory.current;
      final tempFile = File('${currentDir.path}/$fileName');
      await tempFile.writeAsBytes(data);
      return tempFile;
    } catch (e) {
      // Fall through
    }

    try {
      final tempFile = File(fileName);
      await tempFile.writeAsBytes(data);
      return tempFile;
    } catch (e) {
      throw Exception('Cannot create temporary file: $e');
    }
  }

  String _getMimeType(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      default:
        return 'application/octet-stream';
    }
  }

  bool _isVideoFile(String fileName) {
    final videoExtensions = ['mp4', 'mov', 'avi', 'mkv', 'webm', 'flv'];
    final extension = fileName.split('.').last.toLowerCase();
    return videoExtensions.contains(extension);
  }

  bool _isSupabaseUrl(String url) {
    return url.contains('supabase.co/storage');
  }

  bool _isFirebaseUrl(String url) {
    return url.contains('firebasestorage.googleapis.com');
  }

  bool _isGooglePhoto(String url) {
    return url.contains('googleusercontent.com') ||
        url.contains('lh3.googleusercontent.com');
  }

  // ===========================================================================
  // MIGRATION HELPERS
  // ===========================================================================

  Future<String> migrateImageToSupabase(String firebaseUrl) async {
    try {
      final response = await http.get(Uri.parse(firebaseUrl));
      if (response.statusCode != 200) {
        throw Exception(
            'Failed to download image from Firebase: ${response.statusCode}');
      }

      final bytes = response.bodyBytes;
      final fileName = firebaseUrl.split('/').last.split('?').first;

      final supabaseUrl = await uploadImageToSupabase(
        Uint8List.fromList(bytes),
        fileName,
        useUserFolder: true,
      );

      return supabaseUrl;
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'migrate_image_to_supabase',
        userId: userId,
        mediaUrl: firebaseUrl,
        error: e,
      );
      throw Exception('Failed to migrate image to Supabase: $e');
    }
  }

  // ===========================================================================
  // REST API METHODS (INTERNAL)
  // ===========================================================================

  Future<void> _deleteViaRestApi(String bucketName, String filePath) async {
    try {
      final projectRef = 'tbiemcbqjjjsgumnjlqq';
      final anonKey =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRiaWVtY2Jxampqc3VtbmpscXEiLCJyb2xlIjoiYW5vbiIsImlhdCI6MTcyODU1OTY0NywiZXhwIjoyMDQ0MTM1NjQ3fQ.0t_lxOQkF4K9cEEmhJ4w1b2q6y6q2q9Q2q9Q2q9Q2q9Q';

      final List<Map<String, dynamic>> endpoints = [
        {
          'name': 'Single file DELETE',
          'url':
              'https://$projectRef.supabase.co/storage/v1/object/$bucketName/${Uri.encodeComponent(filePath)}',
          'method': 'DELETE',
          'body': null
        },
        {
          'name': 'Batch deletion POST',
          'url':
              'https://$projectRef.supabase.co/storage/v1/object/$bucketName',
          'method': 'POST',
          'body': {
            'prefixes': [filePath]
          }
        },
      ];

      for (var endpoint in endpoints) {
        final String name = endpoint['name'] as String;
        final String url = endpoint['url'] as String;
        final String method = endpoint['method'] as String;
        final dynamic body = endpoint['body'];

        try {
          final uri = Uri.parse(url);
          final http.Response response = method == 'POST'
              ? await http.post(
                  uri,
                  headers: {
                    'Authorization': 'Bearer $anonKey',
                    'Content-Type': 'application/json',
                  },
                  body: body != null ? json.encode(body) : null,
                )
              : await http.delete(
                  uri,
                  headers: {
                    'Authorization': 'Bearer $anonKey',
                  },
                );

          if (response.statusCode == 200 || response.statusCode == 204) {
            await _verifyDeletion(bucketName, filePath);
            return;
          }
        } catch (e) {
          // Continue to next endpoint
        }

        await Future.delayed(Duration(milliseconds: 500));
      }

      throw Exception('All REST API endpoints failed');
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _verifyDeletion(String bucketName, String filePath) async {
    try {
      await Future.delayed(Duration(seconds: 2));

      bool deletionVerified = false;

      try {
        final publicUrl =
            _supabase.storage.from(bucketName).getPublicUrl(filePath);
        final headResponse = await http.head(Uri.parse(publicUrl));

        if (headResponse.statusCode == 404) {
          deletionVerified = true;
        }
      } catch (e) {
        deletionVerified = true;
      }

      if (!deletionVerified) {
        try {
          final userFolder = filePath.split('/').first;
          final files =
              await _supabase.storage.from(bucketName).list(path: userFolder);

          bool fileExists = false;
          for (final file in files) {
            final fileName = file.name;
            if (fileName != null &&
                fileName is String &&
                fileName == filePath.split('/').last) {
              fileExists = true;
              break;
            }
          }

          if (!fileExists) {
            deletionVerified = true;
          }
        } catch (e) {
          deletionVerified = true;
        }
      }
    } catch (e) {
      // Error verifying deletion
    }
  }

  Future<void> deleteMediaByUrl(String mediaUrl) async {
    try {
      if (mediaUrl.isEmpty || mediaUrl == 'default') return;

      if (_isSupabaseUrl(mediaUrl)) {
        if (mediaUrl.contains('/videos/')) {
          final pattern = RegExp(r'storage/v1/object/public/videos/(.+)');
          final match = pattern.firstMatch(mediaUrl);

          if (match != null && match.groupCount >= 1) {
            final filePath = match.group(1)!;
            await deleteVideoFromSupabase('videos', filePath);
          }
        } else if (mediaUrl.contains('/Images/')) {
          final pattern = RegExp(r'storage/v1/object/public/Images/(.+)');
          final match = pattern.firstMatch(mediaUrl);

          if (match != null && match.groupCount >= 1) {
            final filePath = match.group(1)!;
            await deleteImageFromSupabase(filePath);
          }
        }
      }
    } catch (e) {
      final userId = _getCurrentUserId();
      await _logPostError(
        operationType: 'delete_media_by_url',
        userId: userId,
        mediaUrl: mediaUrl,
        error: e,
      );
    }
  }
}
