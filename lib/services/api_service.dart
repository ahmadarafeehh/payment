import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/services/firebase_supabase_service.dart';

class ApiService {
  final String baseUrl = "https://tbiemcbqjjjsgumnjlqq.supabase.co";
  final String apiKey =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRiaWVtY2Jxampqc2d1bW5qbHFxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQzMTQ2NjQsImV4cCI6MjA2OTg5MDY2NH0.JAgFU3fDBGAlMFuHQDqiu35GFe-QYMJfoaIc3mI26yM"; // Add your Supabase API key

  final SupabaseClient _supabase = Supabase.instance.client;

  Future<bool> isMutuallyBlocked(String userId, String otherUserId) async {
    try {
      // Get the current user's blocked users list
      final userResponse = await FirebaseSupabaseService.simpleQuery(
        'users',
        column: 'uid',
        value: userId,
      );

      // Get the other user's blocked users list
      final otherUserResponse = await FirebaseSupabaseService.simpleQuery(
        'users',
        column: 'uid',
        value: otherUserId,
      );

      if (userResponse != null &&
          userResponse.isNotEmpty &&
          otherUserResponse != null &&
          otherUserResponse.isNotEmpty) {
        final userData = userResponse[0] as Map<String, dynamic>;
        final otherUserData = otherUserResponse[0] as Map<String, dynamic>;

        final userBlockedUsers =
            userData['blockedUsers'] as List<dynamic>? ?? [];
        final otherUserBlockedUsers =
            otherUserData['blockedUsers'] as List<dynamic>? ?? [];

        // Check if either user has blocked the other
        final userBlockedOther = userBlockedUsers.contains(otherUserId);
        final otherBlockedUser = otherUserBlockedUsers.contains(userId);

        return userBlockedOther || otherBlockedUser;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<void> recordPostView(String postId, String userId) async {
    await _supabase.from('user_post_views').upsert({
      'user_id': userId,
      'post_id': postId,
      'viewed_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<bool> ratePost(String postId, String userId, double rating) async {
    final response = await _supabase.from('post_rating').upsert({
      'postid': postId,
      'userid': userId,
      'rating': rating,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    return response.error == null;
  }

  Future<void> reportPost(String postId, String reason) async {
    try {
      await http.post(
        Uri.parse('$baseUrl/rest/v1/reports'),
        headers: {
          'apikey': apiKey,
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        },
        body: json.encode({
          'post_id': postId,
          'reason': reason,
          'reported_at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (e) {}
  }

  Future<void> deletePost(String postId) async {
    try {
      await http.delete(
        Uri.parse('$baseUrl/rest/v1/posts?postId=eq.$postId'),
        headers: {
          'apikey': apiKey,
          'Authorization': 'Bearer $apiKey',
        },
      );
    } catch (e) {}
  }
}
