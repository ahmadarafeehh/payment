import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class IAPService {
  static final IAPService _instance = IAPService._internal();
  factory IAPService() => _instance;
  IAPService._internal();

  static const String productId = 'ratedly_plus';

  final SupabaseClient _supabase = Supabase.instance.client;

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  String? get _firebaseUid => FirebaseAuth.instance.currentUser?.uid;

  /// Logs an error to the purchase_errors table.
  /// Does nothing if the insert fails (no fallback logging).
  Future<void> _logError({
    required String operationType,
    required dynamic error,
    StackTrace? stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    final uid = _firebaseUid;
    final errorMessage = error.toString();
    final stackTraceStr = stackTrace?.toString();

    try {
      await _supabase.from('purchase_errors').insert({
        'user_id': uid,
        'operation_type': operationType,
        'error_message': errorMessage,
        'stack_trace': stackTraceStr,
        'additional_data': additionalData,
      });
    } catch (_) {
      // Insertion failed – ignore to avoid infinite loops or console spam.
    }
  }

  // ─── DB read/write ────────────────────────────────────────────────────────────

  /// Writes isPremium to the users table row matching the current Firebase UID.
  Future<void> setPurchased(bool value) async {
    final uid = _firebaseUid;
    if (uid == null) return;

    try {
      await _supabase
          .from('users')
          .update({'isPremium': value})
          .eq('uid', uid);
    } catch (e, st) {
      await _logError(
        operationType: 'setPurchased',
        error: e,
        stackTrace: st,
        additionalData: {'value': value},
      );
    }
  }

  /// Reads isPremium directly from the users table for the current Firebase UID.
  Future<bool> _getPurchasedFromDB() async {
    final uid = _firebaseUid;
    if (uid == null) return false;

    try {
      final row = await _supabase
          .from('users')
          .select('isPremium')
          .eq('uid', uid)
          .maybeSingle();
      return (row?['isPremium'] as bool?) ?? false;
    } catch (e, st) {
      await _logError(
        operationType: '_getPurchasedFromDB',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  // ─── Init ─────────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    try {
      await Purchases.setLogLevel(LogLevel.debug);
      await Purchases.configure(
        PurchasesConfiguration('appl_wMFHqyzgWfgFlLiPkstIsAIQira'),
      );
    } catch (e, st) {
      // Use a temporary instance to log; the static method cannot access _instance.
      // We create a minimal local logger – but since this is static we cannot use _logError.
      // Instead, we insert directly. This is a one‑time edge case.
      try {
        final supabase = Supabase.instance.client;
        await supabase.from('purchase_errors').insert({
          'user_id': FirebaseAuth.instance.currentUser?.uid,
          'operation_type': 'init',
          'error_message': e.toString(),
          'stack_trace': st.toString(),
          'additional_data': null,
        });
      } catch (_) {}
    }
  }

  // ─── Get Product ──────────────────────────────────────────────────────────────

  Future<StoreProduct?> getProduct() async {
    try {
      final offerings = await Purchases.getOfferings();

      if (offerings.current == null) {
        return null;
      }

      if (offerings.current!.availablePackages.isEmpty) {
        return null;
      }

      Package? package;
      try {
        package = offerings.current!.availablePackages.firstWhere(
          (p) => p.storeProduct.identifier == productId,
        );
      } catch (_) {
        package = offerings.current!.availablePackages.first;
      }

      return package.storeProduct;
    } catch (e, st) {
      await _logError(
        operationType: 'getProduct',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  // ─── Purchase ─────────────────────────────────────────────────────────────────

  Future<bool> buyProduct(StoreProduct product) async {
    try {
      final customerInfo = await Purchases.purchaseStoreProduct(product);

      final purchased = _isEntitled(customerInfo);

      if (purchased) {
        await setPurchased(true);
      }

      return purchased;
    } on PurchasesErrorCode catch (e, st) {
      if (e == PurchasesErrorCode.purchaseCancelledError) {
        return false; // Not an error – do not log.
      }
      await _logError(
        operationType: 'buyProduct',
        error: e,
        stackTrace: st,
        additionalData: {'productId': product.identifier},
      );
      rethrow;
    } catch (e, st) {
      await _logError(
        operationType: 'buyProduct',
        error: e,
        stackTrace: st,
        additionalData: {'productId': product.identifier},
      );
      rethrow;
    }
  }

  // ─── Restore ──────────────────────────────────────────────────────────────────

  Future<bool> restorePurchases() async {
    try {
      final customerInfo = await Purchases.restorePurchases();
      final entitled = _isEntitled(customerInfo);

      if (entitled) await setPurchased(true);
      return entitled;
    } catch (e, st) {
      await _logError(
        operationType: 'restorePurchases',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  // ─── Entitlement check ────────────────────────────────────────────────────────

  bool _isEntitled(CustomerInfo info) {
    return info.entitlements.active.containsKey('Reactly: Share & React Pro');
  }

  // ─── isPurchased ──────────────────────────────────────────────────────────────

  Future<bool> isPurchased() async {
    return await _getPurchasedFromDB();
  }
}
