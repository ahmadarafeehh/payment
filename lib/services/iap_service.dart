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

  // ─── Supabase logger ─────────────────────────────────────────────────────────

  Future<void> _log({
    required String step,
    required String status,
    String? userId,
    String? productId,
    String? offeringId,
    String? errorMessage,
    String? errorCode,
    String? extraInfo,
  }) async {
    try {
      await _supabase.from('purchase_logs').insert({
        'user_id': userId,
        'step': step,
        'status': status,
        'product_id': productId,
        'offering_id': offeringId,
        'error_message': errorMessage,
        'error_code': errorCode,
        'extra_info': extraInfo,
      });
    } catch (e) {
      print('[IAPLog] Failed to write log: $e');
    }
  }

  // ─── Init ─────────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    try {
      await Purchases.setLogLevel(LogLevel.debug);
      await Purchases.configure(
        PurchasesConfiguration('appl_wMFHqyzgWfgFlLiPkstIsAIQira'),
      );
      print('[IAP] RevenueCat configured successfully');
    } catch (e) {
      print('[IAP] Failed to configure RevenueCat: $e');
    }
  }

  // ─── DB read/write ────────────────────────────────────────────────────────────

  /// Writes isPremium to the users table row matching the current Firebase UID.
  /// This is account-scoped — only THIS account's row is updated.
  Future<void> setPurchased(bool value) async {
    final uid = _firebaseUid;
    if (uid == null) {
      print('[IAP] setPurchased: no Firebase UID — skipping DB write');
      return;
    }
    try {
      await _supabase
          .from('users')
          .update({'isPremium': value})
          .eq('uid', uid);
      print('[IAP] isPremium=$value written to users table for uid=$uid');
    } catch (e) {
      print('[IAP] Failed to update isPremium in DB: $e');
    }
  }

  /// Reads isPremium directly from the users table for the current Firebase UID.
  /// Returns false if the row is missing, the column is null, or a DB error occurs.
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
    } catch (e) {
      print('[IAP] Failed to read isPremium from DB: $e');
      return false;
    }
  }

  // ─── Get Product ──────────────────────────────────────────────────────────────

  Future<StoreProduct?> getProduct() async {
    await _log(step: 'get_product', status: 'started');
    try {
      await _log(step: 'get_offerings', status: 'fetching');
      final offerings = await Purchases.getOfferings();

      if (offerings.current == null) {
        await _log(
          step: 'get_offerings',
          status: 'failed',
          errorMessage:
              'offerings.current is null — no current offering set in RevenueCat dashboard',
          extraInfo: 'All offerings: ${offerings.all.keys.join(', ')}',
        );
        return null;
      }

      await _log(
        step: 'get_offerings',
        status: 'success',
        offeringId: offerings.current!.identifier,
        extraInfo:
            'Packages: ${offerings.current!.availablePackages.map((p) => p.storeProduct.identifier).join(', ')}',
      );

      if (offerings.current!.availablePackages.isEmpty) {
        await _log(
          step: 'get_product',
          status: 'failed',
          offeringId: offerings.current!.identifier,
          errorMessage: 'No packages in current offering',
        );
        return null;
      }

      Package? package;
      try {
        package = offerings.current!.availablePackages.firstWhere(
          (p) => p.storeProduct.identifier == productId,
        );
        await _log(
          step: 'get_product',
          status: 'found_exact_match',
          productId: package.storeProduct.identifier,
          extraInfo: 'Price: ${package.storeProduct.priceString}',
        );
      } catch (_) {
        package = offerings.current!.availablePackages.first;
        await _log(
          step: 'get_product',
          status: 'using_fallback_product',
          productId: package.storeProduct.identifier,
          extraInfo:
              'Expected $productId but used fallback. Price: ${package.storeProduct.priceString}',
        );
      }

      return package.storeProduct;
    } catch (e) {
      await _log(
        step: 'get_product',
        status: 'exception',
        errorMessage: e.toString(),
        errorCode: e.runtimeType.toString(),
      );
      print('[IAP] Failed to fetch product: $e');
      return null;
    }
  }

  // ─── Purchase ─────────────────────────────────────────────────────────────────

  Future<bool> buyProduct(StoreProduct product) async {
    String? userId;
    try {
      final info = await Purchases.getCustomerInfo();
      userId = info.originalAppUserId;
    } catch (_) {}

    await _log(
      step: 'buy_product',
      status: 'started',
      userId: userId,
      productId: product.identifier,
      extraInfo: 'Price: ${product.priceString}',
    );

    try {
      await _log(
        step: 'purchase_store_product',
        status: 'calling_apple',
        userId: userId,
        productId: product.identifier,
      );

      final customerInfo = await Purchases.purchaseStoreProduct(product);

      await _log(
        step: 'purchase_store_product',
        status: 'apple_returned',
        userId: userId,
        productId: product.identifier,
        extraInfo:
            'Active entitlements: ${customerInfo.entitlements.active.keys.join(', ')}',
      );

      final purchased = _isEntitled(customerInfo);

      if (purchased) {
        // Writes only to this account's DB row — other accounts on the same
        // Apple ID are unaffected
        await setPurchased(true);
        await _log(
          step: 'buy_product',
          status: 'success',
          userId: userId,
          productId: product.identifier,
          extraInfo: 'isPremium set for uid=${_firebaseUid}',
        );
      } else {
        await _log(
          step: 'buy_product',
          status: 'entitlement_not_found',
          userId: userId,
          productId: product.identifier,
          errorMessage:
              'Purchase went through but premium entitlement not found. '
              'Active: ${customerInfo.entitlements.active.keys.join(', ')}',
        );
      }

      return purchased;
    } on PurchasesErrorCode catch (e) {
      if (e == PurchasesErrorCode.purchaseCancelledError) {
        await _log(
          step: 'buy_product',
          status: 'cancelled_by_user',
          userId: userId,
          productId: product.identifier,
        );
        return false;
      }
      await _log(
        step: 'buy_product',
        status: 'purchases_error',
        userId: userId,
        productId: product.identifier,
        errorMessage: e.toString(),
        errorCode: e.index.toString(),
      );
      rethrow;
    } catch (e) {
      await _log(
        step: 'buy_product',
        status: 'exception',
        userId: userId,
        productId: product.identifier,
        errorMessage: e.toString(),
        errorCode: e.runtimeType.toString(),
      );
      rethrow;
    }
  }

  // ─── Restore ──────────────────────────────────────────────────────────────────

  /// Checks RevenueCat for a valid prior purchase on this Apple ID.
  /// If found, grants premium to THIS account only (the currently signed-in
  /// Firebase UID). The user must explicitly restore on each account they want
  /// to enable premium for — it is never automatic.
  Future<bool> restorePurchases() async {
    await _log(
      step: 'restore_purchases',
      status: 'started',
      userId: _firebaseUid,
    );
    try {
      final customerInfo = await Purchases.restorePurchases();
      final entitled = _isEntitled(customerInfo);

      await _log(
        step: 'restore_purchases',
        status: entitled ? 'success' : 'no_purchases_found',
        userId: _firebaseUid,
        extraInfo:
            'Active entitlements: ${customerInfo.entitlements.active.keys.join(', ')}',
      );

      // Only grants premium to THIS account's DB row
      if (entitled) await setPurchased(true);
      return entitled;
    } catch (e) {
      await _log(
        step: 'restore_purchases',
        status: 'exception',
        userId: _firebaseUid,
        errorMessage: e.toString(),
        errorCode: e.runtimeType.toString(),
      );
      print('[IAP] Restore failed: $e');
      return false;
    }
  }

  // ─── Entitlement check ────────────────────────────────────────────────────────

  bool _isEntitled(CustomerInfo info) {
    return info.entitlements.active.containsKey('Reactly: Share & React Pro');
  }

  // ─── isPurchased ──────────────────────────────────────────────────────────────

  /// Source of truth: users.isPremium in the database.
  /// RevenueCat is never consulted here — premium is per account, not per
  /// Apple ID. A user with multiple accounts must explicitly restore purchases
  /// on each account they want to grant premium to.
  Future<bool> isPurchased() async {
    final purchased = await _getPurchasedFromDB();
    await _log(
      step: 'is_purchased_check',
      status: purchased ? 'premium_active' : 'not_premium',
      userId: _firebaseUid,
      extraInfo: 'Read from DB only — account-scoped, no RevenueCat call',
    );
    return purchased;
  }
}
