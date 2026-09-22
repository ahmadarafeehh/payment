import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/services/notification_service.dart';

/// Add this file alongside reactions_methods.dart, e.g.
/// lib/resources/agree_disagree_methods.dart
///
/// SQL to run once in Supabase (mirrors post_rating):
///
/// create table post_agree_disagree (
///   postid text not null,
///   userid text not null,
///   choice text not null check (choice in ('agree', 'disagree')),
///   timestamp timestamptz not null default now(),
///   primary key (postid, userid)
/// );
///
/// alter publication supabase_realtime add table post_agree_disagree;

class SupabaseAgreeDisagreeMethods {
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
  // Set / toggle / clear a user's agree-disagree choice on a post.
  //
  // Behavior (single-choice toggle, matching the app's UX):
  //   - user has no choice yet          -> insert `choice`
  //   - user's existing choice == choice -> delete row (un-vote)
  //   - user's existing choice != choice -> update to `choice`
  //
  // Returns "success" or an error string, same convention as reactToPost.
  // ----------------------
  Future<String> reactToPostAgreeDisagree(
      String postId, String uid, String choice) async {
    assert(choice == 'agree' || choice == 'disagree');
    String res = "Some error occurred";
    String postOwnerUid = '';
    try {
      final postSel = await _supabase
          .from('posts')
          .select('uid')
          .eq('postId', postId)
          .maybeSingle();
      final postData = _unwrap(postSel) ?? postSel;
      if (postData == null) throw Exception('Post not found');
      postOwnerUid = postData['uid']?.toString() ?? '';

      final existing = await _supabase
          .from('post_agree_disagree')
          .select('choice')
          .eq('postid', postId)
          .eq('userid', uid)
          .maybeSingle();
      final existingData = _unwrap(existing) ?? existing;
      final String? existingChoice = existingData?['choice']?.toString();

      if (existingChoice == choice) {
        // Un-vote: tapping the already-active choice clears it.
        await _supabase
            .from('post_agree_disagree')
            .delete()
            .eq('postid', postId)
            .eq('userid', uid);
      } else {
        final bool isSwitch = existingChoice != null;

        await _supabase.from('post_agree_disagree').upsert({
          'postid': postId,
          'userid': uid,
          'choice': choice,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'postid,userid');

        if (uid != postOwnerUid && postOwnerUid.isNotEmpty) {
          if (isSwitch) {
            await _deletePreviousAgreeDisagreeNotification(postId, uid);
          }
          await _createAgreeDisagreeNotification(
            postId: postId,
            postOwnerUid: postOwnerUid,
            reactorUid: uid,
            choice: choice,
          );
        }
      }

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logReactionError(
        operationType: 'react_to_post_agree_disagree',
        userId: uid,
        error: err,
        additionalData: {'postId': postId, 'choice': choice},
      );
    }
    return res;
  }

  Future<void> _deletePreviousAgreeDisagreeNotification(
      String postId, String reactorUid) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('type', 'post_agree_disagree')
          .eq('custom_data->>postId', postId)
          .eq('custom_data->>raterUid', reactorUid);
    } catch (e) {
      await _logReactionError(
        operationType: 'delete_previous_agree_disagree_notification',
        userId: reactorUid,
        error: e,
        additionalData: {'postId': postId},
      );
    }
  }

  Future<void> _createAgreeDisagreeNotification({
    required String postId,
    required String postOwnerUid,
    required String reactorUid,
    required String choice,
  }) async {
    if (reactorUid == postOwnerUid || postOwnerUid.isEmpty) return;

    // DB write
    try {
      await _supabase.from('notifications').insert({
        'type': 'post_agree_disagree',
        'target_user_id': postOwnerUid,
        'custom_data': {
          'postId': postId,
          'raterUid': reactorUid,
          'choice': choice,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await _logReactionError(
        operationType: 'create_agree_disagree_notification_db_write',
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
      // Don't log username fetch errors here; not critical for the main error flow
    }

    // Push notification
    try {
      final verb = choice == 'agree' ? 'agreed with' : 'disagreed with';
      await _notificationService.triggerServerNotification(
        type: 'post_agree_disagree',
        targetUserId: postOwnerUid,
        title: 'New Reaction',
        body: '$reactorUsername $verb your post',
        customData: {'raterId': reactorUid, 'postId': postId},
      );
    } catch (e) {
      await _logReactionError(
        operationType: 'create_agree_disagree_notification_push',
        userId: reactorUid,
        error: e,
        additionalData: {'postId': postId, 'postOwnerUid': postOwnerUid},
      );
    }
  }

  // ----------------------
  // Fetch aggregate agree/disagree counts for a post.
  // ----------------------
  Future<Map<String, int>> getCounts(String postId) async {
    try {
      final rows = await _supabase
          .from('post_agree_disagree')
          .select('choice')
          .eq('postid', postId);
      final list = (rows as List).cast<Map<String, dynamic>>();
      final int agree = list.where((r) => r['choice'] == 'agree').length;
      final int disagree =
          list.where((r) => r['choice'] == 'disagree').length;
      return {'agree': agree, 'disagree': disagree};
    } catch (e) {
      await _logReactionError(
        operationType: 'get_agree_disagree_counts',
        error: e,
        additionalData: {'postId': postId},
      );
      return {'agree': 0, 'disagree': 0};
    }
  }
}
