import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:Ratedly/services/notification_service.dart';

class SupabaseMessagesMethods {
  final SupabaseClient _supabase = Supabase.instance.client;
  final NotificationService _notificationService = NotificationService();
  final Uuid _uuid = Uuid();

  DateTime? _lastExpiryCheckTime;
  static const Duration _expiryCheckThrottle = Duration(hours: 1);

  // Existing sendMessage method remains for backward compatibility
  Future<String> sendMessage(
    String chatId,
    String senderId,
    String receiverId,
    String message,
  ) async {
    return sendMessageWithReply(
      chatId: chatId,
      senderId: senderId,
      receiverId: receiverId,
      message: message,
    );
  }

  Future<String> sendMessageWithReply({
    required String chatId,
    required String senderId,
    required String receiverId,
    required String message,
    Map<String, dynamic>? repliedToMessage,
  }) async {
    try {
      // 1. Get current chat state BEFORE sending
      final currentChat = await _supabase
          .from('chats')
          .select(
              'streak_count, last_mutual_exchange, streak_checked_at, participants')
          .eq('id', chatId)
          .single();

      // 2. Insert the message with reply data
      final Map<String, dynamic> messageData = {
        'chat_id': chatId,
        'sender_id': senderId,
        'receiver_id': receiverId,
        'message': message,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      };

      // Add reply data if we're replying to a message
      if (repliedToMessage != null && repliedToMessage['id'] != null) {
        // Extract the original message text for the preview
        String originalMessageText =
            repliedToMessage['message']?.toString() ?? '';
        if (originalMessageText.length > 30) {
          originalMessageText = '${originalMessageText.substring(0, 30)}...';
        }

        // If it's a post type, use a different preview
        String messagePreview =
            (repliedToMessage['type']?.toString() ?? 'text') == 'post'
                ? 'Shared a post'
                : originalMessageText;

        // Check who sent the original message
        bool isOriginalSenderSelf =
            repliedToMessage['senderId']?.toString() == senderId;

        messageData['replied_to_message_id'] =
            repliedToMessage['id']?.toString();
        messageData['is_reply'] = true;
        messageData['replied_message_preview'] = messagePreview;
        messageData['replied_message_sender'] = isOriginalSenderSelf;
        messageData['replied_message_type'] =
            repliedToMessage['type']?.toString() ?? 'text';
      }

      await _supabase.from('messages').insert(messageData).select().single();

      // 3. Wait for trigger to complete
      await Future.delayed(Duration(seconds: 1));

      // 4. Get updated chat state
      final updatedChat = await _supabase
          .from('chats')
          .select(
              'streak_count, last_mutual_exchange, streak_checked_at, last_updated, last_message')
          .eq('id', chatId)
          .single();

      // 5. Analyze streak changes
      final oldStreak = currentChat['streak_count'] ?? 0;
      final newStreak = updatedChat['streak_count'] ?? 0;
      final streakChange = newStreak - oldStreak;

      if (streakChange > 0) {
        _sendStreakNotification(chatId, senderId, receiverId, newStreak);
      }

      // 6. Send push notification for the new message
      try {
        // Fetch sender's username for the notification title
        final senderData = await _supabase
            .from('users')
            .select('username')
            .eq('uid', senderId)
            .single();
        final senderName = senderData['username'] ?? 'Someone';

        await _notificationService.triggerServerNotification(
          type: 'message',
          targetUserId: receiverId,
          title: '$senderName sent you a message',
          body:
              message.length > 30 ? '${message.substring(0, 30)}...' : message,
          customData: {
            'senderId': senderId,
            'chatId': chatId,
            'streakCount': newStreak,
            'message': message,
            'isReply': repliedToMessage != null,
            'repliedToMessageId': repliedToMessage?['id']?.toString(),
          },
        );
      } catch (e) {
        // Notification error handled silently
      }

      return 'success';
    } catch (e) {
      return 'error: ${e.toString()}';
    }
  }

  // Paginated messages fetch
  Future<List<Map<String, dynamic>>> getMessagesPaginated(
    String chatId, {
    required int page,
    required int limit,
    DateTime? olderThan,
  }) async {
    try {
      final offset = page * limit;
      final query = _supabase.from('messages').select().eq('chat_id', chatId);
      final filteredQuery = olderThan != null
          ? query.lt('timestamp', olderThan.toIso8601String())
          : query;
      final orderedQuery = filteredQuery.order('timestamp', ascending: false);
      final paginatedQuery = orderedQuery.range(offset, offset + limit - 1);
      final response = await paginatedQuery;

      List<Map<String, dynamic>> messages = (response as List).map((message) {
        dynamic postShare = message['post_share'];
        Map<String, dynamic>? postShareData;
        if (postShare != null && postShare is Map) {
          postShareData = Map<String, dynamic>.from(postShare);
        }

        final repliedMessageSenderValue = message['replied_message_sender'];
        String repliedMessageSender;
        if (repliedMessageSenderValue == null) {
          repliedMessageSender = 'Them';
        } else if (repliedMessageSenderValue is bool) {
          repliedMessageSender =
              repliedMessageSenderValue == true ? 'You' : 'Them';
        } else if (repliedMessageSenderValue is String) {
          repliedMessageSender =
              repliedMessageSenderValue.toLowerCase() == 'true'
                  ? 'You'
                  : 'Them';
        } else {
          repliedMessageSender = 'Them';
        }

        return {
          'id': message['id'].toString(),
          'message': message['message']?.toString() ?? '',
          'senderId': message['sender_id']?.toString() ?? '',
          'receiverId': message['receiver_id']?.toString() ?? '',
          'timestamp': DateTime.parse(message['timestamp'].toString()),
          'isRead': message['is_read'] as bool? ?? false,
          'delivered': message['delivered'] as bool? ?? false,
          'type': postShareData != null ? 'post' : 'text',
          'postShare': postShareData,
          'isReply': message['is_reply'] == true,
          'repliedToMessageId': message['replied_to_message_id']?.toString(),
          'repliedMessagePreview':
              message['replied_message_preview']?.toString() ?? '',
          'repliedMessageSender': repliedMessageSender,
          'repliedMessageType':
              message['replied_message_type']?.toString() ?? 'text',
        };
      }).toList();

      return messages.reversed.toList();
    } catch (e) {
      return [];
    }
  }

  // Streak notification when streak increases
  Future<void> _sendStreakNotification(String chatId, String senderId,
      String receiverId, int streakCount) async {
    try {
      final senderData = await _supabase
          .from('users')
          .select('username')
          .eq('uid', senderId)
          .single();
      final senderName = senderData['username'] ?? 'Someone';

      await _notificationService.triggerServerNotification(
        type: 'streak_update',
        targetUserId: receiverId,
        title: '🔥 Streak Updated!',
        body: '$senderName: Streak is now $streakCount days! Keep it going!',
        customData: {
          'chatId': chatId,
          'streakCount': streakCount,
          'senderId': senderId,
        },
      );
    } catch (e) {
      // Streak notification error handled silently
    }
  }

  // NEW: Check for expiring streaks and send warning notifications (throttled)
  Future<void> checkAndSendStreakExpiryNotifications(
      {bool force = false}) async {
    if (!force && _lastExpiryCheckTime != null) {
      final elapsed = DateTime.now().toUtc().difference(_lastExpiryCheckTime!);
      if (elapsed < _expiryCheckThrottle) {
        return; // throttle – do not run too often
      }
    }
    _lastExpiryCheckTime = DateTime.now().toUtc();

    try {
      final chats = await _supabase
          .from('chats')
          .select(
              'id, participants, streak_count, last_mutual_exchange, streak_expiry_notified_at')
          .gt('streak_count', 0)
          .not('last_mutual_exchange', 'is', null);

      final now = DateTime.now().toUtc();
      const warningHours = 5;

      for (final chat in chats) {
        final lastMutualExchange =
            DateTime.parse(chat['last_mutual_exchange'].toString()).toUtc();
        final expiryTime = lastMutualExchange.add(Duration(hours: 24));
        final timeLeft = expiryTime.difference(now);

        if (timeLeft.isNegative) continue; // already expired
        if (timeLeft.inHours > warningHours) continue; // not yet warning

        final notifiedAtRaw = chat['streak_expiry_notified_at'];
        DateTime? notifiedAt;
        if (notifiedAtRaw != null) {
          notifiedAt = DateTime.parse(notifiedAtRaw.toString()).toUtc();
        }

        // Only send if we haven't notified for this specific mutual exchange
        if (notifiedAt == null || notifiedAt.isBefore(lastMutualExchange)) {
          final participants = List<String>.from(chat['participants']);
          final streakCount = chat['streak_count'] as int;

          final usersData = await _supabase
              .from('users')
              .select('uid, username')
              .inFilter('uid', participants);
          final userMap = {
            for (var u in usersData) u['uid']: u['username'] ?? 'Someone'
          };

          for (final uid in participants) {
            final otherUsername = participants.firstWhere((id) => id != uid,
                orElse: () => 'the other user');
            final otherName = userMap[otherUsername] ?? 'the other user';

            await _notificationService.triggerServerNotification(
              type: 'streak_expiring',
              targetUserId: uid,
              title: '⏳ Streak Expiring Soon!',
              body:
                  'Your $streakCount-day streak with $otherName will expire in less than $warningHours hours. Send a message to keep it alive!',
              customData: {
                'chatId': chat['id'],
                'streakCount': streakCount,
                'expiresAt': expiryTime.toIso8601String(),
                'otherUserId': otherUsername,
              },
            );
          }

          // Mark that we sent the warning for this expiry window
          await _supabase
              .from('chats')
              .update({'streak_expiry_notified_at': now.toIso8601String()}).eq(
                  'id', chat['id']);
        }
      }
    } catch (e) {
      // Silently fail – do not break other operations
    }
  }

  // Helper to get message preview
  String _getMessagePreview(Map<String, dynamic> message) {
    if (message['type'] == 'post') return 'Shared a post';
    String text = message['message'] ?? '';
    return text.length > 30 ? '${text.substring(0, 30)}...' : text;
  }

  Future<String> _getUsername(String userId) async {
    try {
      final response = await _supabase
          .from('users')
          .select('username')
          .eq('uid', userId)
          .single();
      return response['username'] ?? 'Unknown';
    } catch (e) {
      return 'Unknown';
    }
  }

  Stream<List<Map<String, dynamic>>> getMessages(String chatId) {
    return _supabase
        .from('messages')
        .select()
        .eq('chat_id', chatId)
        .order('timestamp')
        .asStream()
        .map((messages) => messages.map((message) {
              dynamic postShare = message['post_share'];
              Map<String, dynamic>? postShareData;
              if (postShare != null && postShare is Map) {
                postShareData = Map<String, dynamic>.from(postShare);
              }

              final repliedMessageSenderValue =
                  message['replied_message_sender'];
              String repliedMessageSender;
              if (repliedMessageSenderValue == null) {
                repliedMessageSender = 'Them';
              } else if (repliedMessageSenderValue is bool) {
                repliedMessageSender =
                    repliedMessageSenderValue == true ? 'You' : 'Them';
              } else if (repliedMessageSenderValue is String) {
                repliedMessageSender =
                    repliedMessageSenderValue.toLowerCase() == 'true'
                        ? 'You'
                        : 'Them';
              } else {
                repliedMessageSender = 'Them';
              }

              return {
                'id': message['id'],
                'message': message['message']?.toString() ?? '',
                'senderId': message['sender_id']?.toString() ?? '',
                'receiverId': message['receiver_id']?.toString() ?? '',
                'timestamp': DateTime.parse(message['timestamp'].toString()),
                'isRead': message['is_read'] as bool? ?? false,
                'delivered': message['delivered'] as bool? ?? false,
                'type': postShareData != null ? 'post' : 'text',
                'postShare': postShareData,
                'isReply': message['is_reply'] as bool? ?? false,
                'repliedToMessageId':
                    message['replied_to_message_id']?.toString(),
                'repliedMessagePreview':
                    message['replied_message_preview']?.toString() ?? '',
                'repliedMessageSender': repliedMessageSender,
                'repliedMessageType':
                    message['replied_message_type']?.toString() ?? 'text',
              };
            }).toList());
  }

  Future<Map<String, dynamic>?> getMessageById(String messageId) async {
    try {
      final message = await _supabase
          .from('messages')
          .select()
          .eq('id', messageId)
          .single();

      dynamic postShare = message['post_share'];
      Map<String, dynamic>? postShareData;
      if (postShare != null && postShare is Map) {
        postShareData = Map<String, dynamic>.from(postShare);
      }

      final repliedMessageSenderValue = message['replied_message_sender'];
      String repliedMessageSender;
      if (repliedMessageSenderValue == null) {
        repliedMessageSender = 'Them';
      } else if (repliedMessageSenderValue is bool) {
        repliedMessageSender =
            repliedMessageSenderValue == true ? 'You' : 'Them';
      } else if (repliedMessageSenderValue is String) {
        repliedMessageSender =
            repliedMessageSenderValue.toLowerCase() == 'true' ? 'You' : 'Them';
      } else {
        repliedMessageSender = 'Them';
      }

      return {
        'id': message['id'],
        'message': message['message']?.toString() ?? '',
        'senderId': message['sender_id']?.toString() ?? '',
        'receiverId': message['receiver_id']?.toString() ?? '',
        'timestamp': DateTime.parse(message['timestamp'].toString()),
        'isRead': message['is_read'] as bool? ?? false,
        'delivered': message['delivered'] as bool? ?? false,
        'type': postShareData != null ? 'post' : 'text',
        'postShare': postShareData,
        'isReply': message['is_reply'] as bool? ?? false,
        'repliedToMessageId': message['replied_to_message_id']?.toString(),
        'repliedMessagePreview':
            message['replied_message_preview']?.toString() ?? '',
        'repliedMessageSender': repliedMessageSender,
        'repliedMessageType':
            message['replied_message_type']?.toString() ?? 'text',
      };
    } catch (e) {
      return null;
    }
  }

  Future<String> getOrCreateChat(String user1, String user2) async {
    try {
      final chatResponse = await _supabase
          .from('chats')
          .select('id, streak_count, last_mutual_exchange, participants')
          .contains('participants', [user1, user2]);
      if (chatResponse.isNotEmpty) {
        return chatResponse[0]['id'];
      }

      final newChatId = _uuid.v1();
      await _supabase.from('chats').insert({
        'id': newChatId,
        'participants': [user1, user2],
        'last_message': '',
        'streak_count': 0,
        'last_mutual_exchange': null,
      });
      return newChatId;
    } catch (e) {
      return e.toString();
    }
  }

  Stream<int> getTotalUnreadCount(String currentUserId) {
    return _supabase
        .from('messages')
        .select()
        .eq('receiver_id', currentUserId)
        .eq('is_read', false)
        .asStream()
        .map((messages) => messages.length);
  }

  Stream<int> getUnreadCount(String chatId, String currentUserId) {
    return _supabase
        .from('messages')
        .select()
        .eq('chat_id', chatId)
        .eq('receiver_id', currentUserId)
        .eq('is_read', false)
        .asStream()
        .map((messages) => messages.length);
  }

  Future<void> markMessagesAsRead(String chatId, String currentUserId) async {
    try {
      await _supabase
          .from('messages')
          .update({'is_read': true})
          .eq('chat_id', chatId)
          .eq('receiver_id', currentUserId)
          .eq('is_read', false);
    } catch (e) {
      // ignore
    }
  }

  Future<void> markMessageAsDelivered(String messageId) async {
    try {
      await _supabase
          .from('messages')
          .update({'delivered': true}).eq('id', messageId);
    } catch (e) {
      // ignore
    }
  }

  Future<void> markMessageAsSeen(String messageId) async {
    try {
      await _supabase
          .from('messages')
          .update({'is_read': true, 'delivered': true}).eq('id', messageId);
    } catch (e) {
      // ignore
    }
  }

  Future<void> deleteAllUserMessages(String uid) async {
    try {
      final chatsResponse = await _supabase
          .from('chats')
          .select('id')
          .contains('participants', [uid]);
      if (chatsResponse.isNotEmpty) {
        final chatIds =
            chatsResponse.map((chat) => chat['id'] as String).toList();
        for (final chatId in chatIds) {
          await _supabase.from('messages').delete().eq('chat_id', chatId);
        }
        for (final chatId in chatIds) {
          await _supabase.from('chats').delete().eq('id', chatId);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  Stream<List<Map<String, dynamic>>> getUserChats(String userId) {
    return _supabase
        .from('chats')
        .select()
        .contains('participants', [userId])
        .order('last_updated', ascending: false)
        .asStream()
        .map((chats) => chats
            .map((chat) => {
                  'id': chat['id'],
                  'participants': List<String>.from(chat['participants']),
                  'lastMessage': chat['last_message'],
                  'lastUpdated': DateTime.parse(chat['last_updated']),
                  'streakCount': chat['streak_count'] ?? 0,
                  'streakCheckedAt': chat['streak_checked_at'],
                  'lastMutualExchange': chat['last_mutual_exchange'],
                })
            .toList());
  }

  Future<int> getStreakCount(String chatId) async {
    try {
      final response = await _supabase
          .from('chats')
          .select('streak_count')
          .eq('id', chatId)
          .single();
      return response['streak_count'] ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<int> getStreakBetweenUsers(String user1, String user2) async {
    try {
      final chatResponse = await _supabase
          .from('chats')
          .select('streak_count')
          .contains('participants', [user1, user2]).single();
      return chatResponse['streak_count'] ?? 0;
    } catch (e) {
      return 0;
    }
  }
}
