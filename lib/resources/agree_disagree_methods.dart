import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/services/notification_service.dart';

/// lib/resources/agree_disagree_methods.dart
///
/// This version targets a SPECIFIC REACTION (postid + target_userid),
/// not the post as a whole. Any viewer can agree/disagree with any
/// individual person's reaction shown in the reactions list — including
/// their own.
///
/// SQL to run once in Supabase:
///
/// create table reaction_agree_disagree (
///   postid text not null,
///   target_userid text not null,   -- whose reaction this vote is about
///   voter_userid text not null,    -- who is casting agree/disagree
///   choice text not null check (choice in ('agree', 'disagree')),
///   timestamp timestamptz not null default now(),
///   primary key (postid, target_userid, voter_userid)
/// );
///
/// alter publication supabase_realtime add table reaction_agree_disagree;

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
      // Fail silently – logging must not crash the app
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
  // Fetch all agree/disagree data for every reaction on a post, in one query.
  // Returns: { targetUserId: { 'agree': n, 'disagree': n, 'viewerChoice': 'agree'|'disagree'|null } }
  // ----------------------
  Future<Map<String, Map<String, dynamic>>> getReactionVotesForPost(
      String postId, String viewerUserId) async {
    final Map<String, Map<String, dynamic>> result = {};
    try {
      final rows = await _supabase
          .from('reaction_agree_disagree')
          .select('target_userid, voter_userid, choice')
          .eq('postid', postId);

      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final targetId = r['target_userid']?.toString();
        final voterId = r['voter_userid']?.toString();
        final choice = r['choice']?.toString();
        if (targetId == null || choice == null) continue;

        result.putIfAbsent(
            targetId, () => {'agree': 0, 'disagree': 0, 'viewerChoice': null});

        if (choice == 'agree') {
          result[targetId]!['agree'] = (result[targetId]!['agree'] as int) + 1;
        } else if (choice == 'disagree') {
          result[targetId]!['disagree'] =
              (result[targetId]!['disagree'] as int) + 1;
        }

        if (voterId == viewerUserId) {
          result[targetId]!['viewerChoice'] = choice;
        }
      }
    } catch (e) {
      await _logReactionError(
        operationType: 'get_reaction_votes_for_post',
        userId: viewerUserId,
        error: e,
        additionalData: {'postId': postId},
      );
    }
    return result;
  }

  // ----------------------
  // Fetch agree/disagree data for ONE specific reaction (postid + targetUserId).
  // Lighter than getReactionVotesForPost when only one row is needed —
  // e.g. a single notification showing one person's reaction.
  // Returns { 'agree': int, 'disagree': int, 'viewerChoice': String? }
  // ----------------------
  Future<Map<String, dynamic>> getVotesForReaction({
    required String postId,
    required String targetUserId,
    required String viewerUserId,
  }) async {
    final Map<String, dynamic> result = {
      'agree': 0,
      'disagree': 0,
      'viewerChoice': null,
    };
    try {
      final rows = await _supabase
          .from('reaction_agree_disagree')
          .select('voter_userid, choice')
          .eq('postid', postId)
          .eq('target_userid', targetUserId);

      for (final r in (rows as List).cast<Map<String, dynamic>>()) {
        final voterId = r['voter_userid']?.toString();
        final choice = r['choice']?.toString();
        if (choice == 'agree') {
          result['agree'] = (result['agree'] as int) + 1;
        } else if (choice == 'disagree') {
          result['disagree'] = (result['disagree'] as int) + 1;
        }
        if (voterId == viewerUserId) {
          result['viewerChoice'] = choice;
        }
      }
    } catch (e) {
      await _logReactionError(
        operationType: 'get_votes_for_reaction',
        userId: viewerUserId,
        error: e,
        additionalData: {'postId': postId, 'targetUserId': targetUserId},
      );
    }
    return result;
  }

  // ----------------------
  // Cast/toggle/clear the current viewer's agree-disagree vote on a
  // specific person's reaction.
  //
  // Behavior (single-choice toggle):
  //   - viewer has no vote on this reaction yet -> insert `choice`
  //   - viewer's existing vote == choice         -> delete row (un-vote)
  //   - viewer's existing vote != choice          -> update to `choice`
  //
  // Returns "success" or an error string.
  // ----------------------
  Future<String> voteOnReaction({
    required String postId,
    required String targetUserId, // whose reaction is being voted on
    required String voterUserId, // who is voting
    required String choice, // 'agree' or 'disagree'
  }) async {
    assert(choice == 'agree' || choice == 'disagree');
    String res = "Some error occurred";
    try {
      final existing = await _supabase
          .from('reaction_agree_disagree')
          .select('choice')
          .eq('postid', postId)
          .eq('target_userid', targetUserId)
          .eq('voter_userid', voterUserId)
          .maybeSingle();
      final existingData = _unwrap(existing) ?? existing;
      final String? existingChoice = existingData?['choice']?.toString();

      if (existingChoice == choice) {
        // Un-vote: tapping the already-active choice clears it.
        await _supabase
            .from('reaction_agree_disagree')
            .delete()
            .eq('postid', postId)
            .eq('target_userid', targetUserId)
            .eq('voter_userid', voterUserId);
      } else {
        final bool isSwitch = existingChoice != null;

        await _supabase.from('reaction_agree_disagree').upsert({
          'postid': postId,
          'target_userid': targetUserId,
          'voter_userid': voterUserId,
          'choice': choice,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'postid,target_userid,voter_userid');

        // Notify the reaction's owner (unless they're voting on their own reaction)
        if (voterUserId != targetUserId) {
          if (isSwitch) {
            await _deletePreviousVoteNotification(
                postId, targetUserId, voterUserId);
          }
          await _createVoteNotification(
            postId: postId,
            targetUserId: targetUserId,
            voterUserId: voterUserId,
            choice: choice,
          );
        }
      }

      res = "success";
    } catch (err) {
      res = err.toString();
      await _logReactionError(
        operationType: 'vote_on_reaction',
        userId: voterUserId,
        error: err,
        additionalData: {
          'postId': postId,
          'targetUserId': targetUserId,
          'choice': choice,
        },
      );
    }
    return res;
  }

  Future<void> _deletePreviousVoteNotification(
      String postId, String targetUserId, String voterUserId) async {
    try {
      await _supabase
          .from('notifications')
          .delete()
          .eq('type', 'reaction_agree_disagree')
          .eq('custom_data->>postId', postId)
          .eq('custom_data->>targetUserId', targetUserId)
          .eq('custom_data->>voterUserId', voterUserId);
    } catch (e) {
      await _logReactionError(
        operationType: 'delete_previous_vote_notification',
        userId: voterUserId,
        error: e,
        additionalData: {'postId': postId, 'targetUserId': targetUserId},
      );
    }
  }

  Future<void> _createVoteNotification({
    required String postId,
    required String targetUserId,
    required String voterUserId,
    required String choice,
  }) async {
    // DB write
    try {
      await _supabase.from('notifications').insert({
        'type': 'reaction_agree_disagree',
        'target_user_id': targetUserId,
        'custom_data': {
          'postId': postId,
          'targetUserId': targetUserId,
          'voterUserId': voterUserId,
          'choice': choice,
        },
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await _logReactionError(
        operationType: 'create_vote_notification_db_write',
        userId: voterUserId,
        error: e,
        additionalData: {'postId': postId, 'targetUserId': targetUserId},
      );
    }

    // Resolve voter username
    String voterUsername = 'Someone';
    try {
      final voterSel = await _supabase
          .from('users')
          .select('username')
          .eq('uid', voterUserId)
          .maybeSingle();
      final voterData = _unwrap(voterSel) ?? voterSel;
      voterUsername = voterData?['username'] ?? 'Someone';
    } catch (_) {
      // Not critical
    }

    // Push notification
    try {
      final verb = choice == 'agree' ? 'agreed with' : 'disagreed with';
      await _notificationService.triggerServerNotification(
        type: 'reaction_agree_disagree',
        targetUserId: targetUserId,
        title: 'New Reaction',
        body: '$voterUsername $verb your reaction',
        customData: {'voterId': voterUserId, 'postId': postId},
      );
    } catch (e) {
      await _logReactionError(
        operationType: 'create_vote_notification_push',
        userId: voterUserId,
        error: e,
        additionalData: {'postId': postId, 'targetUserId': targetUserId},
      );
    }
  }
}
