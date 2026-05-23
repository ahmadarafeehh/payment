import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationService {
  static Future<void> markNotificationsAsRead(String userId) async {
    try {
      final supabase = Supabase.instance.client;

      // Update all unread notifications for this user to mark them as read
      await supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('target_user_id', userId)
          .eq('is_read', false);
    } catch (e) {
      rethrow;
    }
  }
}
