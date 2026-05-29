import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/services/notification_service.dart';

class SupabaseReactionsMethods {
  final SupabaseClient _supabase = Supabase.instance.client;
  final NotificationService _notificationService = NotificationService();

  // ===========================================================================
  // ERROR LOGGING HELPER – logs only to reactions_error table
  // ===========================================================================
  Future<void> _logReactionError({
    required String operationType,
    String? userId,
    required dynamic error,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _supabase.from('reactions_error').insert({
        'user_id': userId,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': error is Error ? error.stackTrace?.toString() : null,
        'additional_data': additionalData,
      });
    } catch (_) {
      // Fail silently – error logging must not crash the app
    }
  }

  dynamic _unwrap(dynamic res) {
    try {
      if (res == null) return null;
      if (res is Map && res.containsKey('data')) return res['data'];
    } catch (_) {}
    return res;
  }

  // ----------------------
  // React to a post (formerly ratePost)
  // ----------------------
  Future<String> reactToPost(
      String postId, String uid, double reactionValue) async {
    String res = "Some error occurred";
    String postOwnerUid = '';
    try {
      final roundedReaction = double.parse(reactionValue.toStringAsFixed(1));

      final postSel = await _supabase
          .from('posts')
          .select('uid')
          .eq('postId', postId)
          .maybeSingle();
      final postData = _unwrap(postSel) ?? postSel;
      if (postData == null) throw Exception('Post not found');
      postOwnerUid = postData['uid']?.toString() ?? '';

      final existingReaction = await _supabase
          .from('post_rating')
          .select('rating')
          .eq('postid', postId)
          .eq('userid', uid)
          .maybeSingle();

      final bool isUpdate = existingReaction != null;

      await _supabase.from('post_rating').upsert({
        'postid': postId,
        'userid': uid,
        'rating': roundedReaction,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'postid,userid');

      if (uid != postOwnerUid && postOwnerUid.isNotEmpty) {
        if (isUpdate) {
          await _deletePreviousReactionNotification(postId, uid);
        }
        await _createReactionNotification(
          postId: postId,
          postOwnerUid: postOwnerUid,
          reactorUid: uid,
          reactionValue: roundedReaction,
        );
      }

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logReactionError(
        operationType: 'react_to_post',
        userId: uid,
        error: err,
        additionalData: {'postId': postId, 'reactionValue': reactionValue},
      );
    }
    return res;
  }

  Future<void> _deletePreviousReactionNotification(
      String postId, String reactorUid) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('type', 'post_rating')
          .eq('custom_data->>postId', postId)
          .eq('custom_data->>raterUid', reactorUid);
    } catch (e) {
      await _logReactionError(
        operationType: 'delete_previous_reaction_notification',
        userId: reactorUid,
        error: e,
        additionalData: {'postId': postId},
      );
    }
  }

  Future<void> _createReactionNotification({
    required String postId,
    required String postOwnerUid,
    required String reactorUid,
    required double reactionValue,
  }) async {
    if (reactorUid == postOwnerUid || postOwnerUid.isEmpty) return;

    // DB write
    try {
      await _supabase.from('notifications').insert({
        'type': 'post_rating',
        'target_user_id': postOwnerUid,
        'custom_data': {
          'postId': postId,
          'raterUid': reactorUid,
          'rating': reactionValue,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await _logReactionError(
        operationType: 'create_reaction_notification_db_write',
        userId: reactorUid,
        error: e,
        additionalData: {'postId': postId, 'postOwnerUid': postOwnerUid},
      );
    }

    // Resolve username
    String reactorUsername = 'Someone';
    try {
      final reactorSel = await _supabase
          .from('users')
          .select('username')
          .eq('uid', reactorUid)
          .maybeSingle();
      final reactorData = _unwrap(reactorSel) ?? reactorSel;
      reactorUsername = reactorData?['username'] ?? 'Someone';
    } catch (_) {
      // Don't log username fetch errors here; they are not critical for the main error flow
    }

    // Push notification
    try {
      await _notificationService.triggerServerNotification(
        type: 'post_rating',
        targetUserId: postOwnerUid,
        title: 'New Reaction',
        body: '$reactorUsername reacted to your post',
        customData: {'raterId': reactorUid, 'postId': postId},
      );
    } catch (e) {
      await _logReactionError(
        operationType: 'create_reaction_notification_push',
        userId: reactorUid,
        error: e,
        additionalData: {'postId': postId, 'postOwnerUid': postOwnerUid},
      );
    }
  }
}
