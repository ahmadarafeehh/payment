import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

class FirebaseSupabaseService {
  static final SupabaseClient _supabase = Supabase.instance.client;

  /// Get the current Firebase user's UID
  static String? get currentUserId => FirebaseAuth.instance.currentUser?.uid;

  /// Check if user is authenticated with Firebase
  static bool get isAuthenticated => FirebaseAuth.instance.currentUser != null;

  /// Debug authentication state
  static Future<void> debugAuthState() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      try {
        final token = await currentUser.getIdToken();
        final idTokenResult = await currentUser.getIdTokenResult(true);
        final claims = idTokenResult.claims;
      } catch (e) {}
    } else {}
  }

  /// Make authenticated query - Supabase will automatically use the Firebase token
  static Future<dynamic> query(
    String table, {
    Map<String, dynamic>? filters,
    int? limit,
    String? orderBy,
    bool ascending = true,
  }) async {
    try {
      // Start with base query
      final baseQuery = _supabase.from(table).select();

      // Apply filters
      PostgrestTransformBuilder<List<Map<String, dynamic>>> queryWithFilters;
      if (filters != null && filters.isNotEmpty) {
        var filteredQuery = baseQuery;
        filters.forEach((key, value) {
          filteredQuery = filteredQuery.eq(key, value);
        });
        queryWithFilters = filteredQuery;
      } else {
        queryWithFilters = baseQuery;
      }

      // Apply ordering
      PostgrestTransformBuilder<List<Map<String, dynamic>>> queryWithOrder;
      if (orderBy != null) {
        queryWithOrder = queryWithFilters.order(orderBy, ascending: ascending);
      } else {
        queryWithOrder = queryWithFilters;
      }

      // Apply limit
      PostgrestTransformBuilder<List<Map<String, dynamic>>> finalQuery;
      if (limit != null) {
        finalQuery = queryWithOrder.limit(limit);
      } else {
        finalQuery = queryWithOrder;
      }

      final response = await finalQuery;
      return response;
    } catch (e) {
      rethrow;
    }
  }

  /// Insert data with Firebase authentication
  static Future<dynamic> insert(String table, Map<String, dynamic> data) async {
    try {
      final response = await _supabase.from(table).insert(data);
      return response;
    } catch (e) {
      rethrow;
    }
  }

  /// Update data with Firebase authentication
  static Future<dynamic> update(
    String table, {
    required Map<String, dynamic> updates,
    required Map<String, dynamic> filters,
  }) async {
    try {
      var query = _supabase.from(table).update(updates);

      // Apply each filter individually
      filters.forEach((key, value) {
        query = query.eq(key, value);
      });

      final response = await query;
      return response;
    } catch (e) {
      rethrow;
    }
  }

  /// Delete data with Firebase authentication
  static Future<dynamic> delete(
    String table, {
    required Map<String, dynamic> filters,
  }) async {
    try {
      var query = _supabase.from(table).delete();

      // Apply each filter individually
      filters.forEach((key, value) {
        query = query.eq(key, value);
      });

      final response = await query;
      return response;
    } catch (e) {
      rethrow;
    }
  }

  /// Test if RLS is working with Firebase auth
  static Future<bool> testRLSAccess() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return false;

      // Try to access user-specific data
      final response = await _supabase
          .from('users')
          .select()
          .eq('uid', currentUser.uid)
          .maybeSingle();

      return response != null;
    } catch (e) {
      return false;
    }
  }

  /// Simplified query method for common use cases
  static Future<dynamic> simpleQuery(
    String table, {
    String? column,
    dynamic value,
  }) async {
    try {
      if (column != null && value != null) {
        return await _supabase.from(table).select().eq(column, value);
      } else {
        return await _supabase.from(table).select();
      }
    } catch (e) {
      rethrow;
    }
  }
}
