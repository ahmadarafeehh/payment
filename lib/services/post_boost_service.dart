// lib/resources/post_boost_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Handles the one-time "Boost Post" in-app purchase and applies the
/// resulting visibility boost to the purchased post in Supabase.
///
/// Mirrors the structure of [IAPService] but is scoped to a single,
/// consumable purchase tied to a specific postId rather than a
/// subscription entitlement.
///
/// Every meaningful step is logged to `purchase_logs` (status: 'start',
/// 'success', 'error', 'cancelled', etc.) and unexpected failures are
/// additionally logged to `purchase_errors` with a stack trace.
class PostBoostService {
  static final PostBoostService _instance = PostBoostService._internal();
  factory PostBoostService() => _instance;
  PostBoostService._internal();

  /// RevenueCat product identifier — must match App Store Connect + RC exactly.
  static const String productId = 'boost_30';

  /// RevenueCat offering identifier.
  static const String _offeringId = 'boost';

  /// RevenueCat package identifier inside the offering.
  static const String _packageId = 'boost_package';

  /// Number of NEW reactions the post must receive (on top of its count at
  /// purchase time) before the boost automatically expires. Enforced by the
  /// `trg_post_rating_boost_expiry` trigger in Supabase.
  static const int targetNewReactions = 30;

  // Cache the resolved package to avoid re-fetching on buyBoost.
  Package? _cachedPackage;

  final SupabaseClient _supabase = Supabase.instance.client;

  String? get _firebaseUid => FirebaseAuth.instance.currentUser?.uid;

  // ─── Logging: purchase_logs ────────────────────────────────────────────────

  /// Inserts a row into `purchase_logs`. Never throws — logging failures
  /// must not interfere with the purchase flow itself.
  Future<void> _log({
    required String step,
    required String status,
    String? productId,
    String? offeringId,
    String? errorMessage,
    String? errorCode,
    String? extraInfo,
  }) async {
    try {
      await _supabase.from('purchase_logs').insert({
        'user_id': _firebaseUid,
        'step': step,
        'status': status,
        'product_id': productId,
        'offering_id': offeringId,
        'error_message': errorMessage,
        'error_code': errorCode,
        'extra_info': extraInfo,
      });
    } catch (_) {
      // Swallow — logging must never break the purchase flow.
    }
  }

  // ─── Logging: purchase_errors ──────────────────────────────────────────────

  /// Inserts a row into `purchase_errors` with full error + stack trace
  /// detail. Never throws.
  Future<void> _logError({
    required String operationType,
    required dynamic error,
    StackTrace? stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _supabase.from('purchase_errors').insert({
        'user_id': _firebaseUid,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': stackTrace?.toString(),
        'additional_data': additionalData,
      });
    } catch (_) {
      // Insertion failed – ignore to avoid infinite loops or console spam.
    }
  }

  // ─── Get Product ──────────────────────────────────────────────────────────

  /// Fetches the boost product from the dedicated 'boost' offering.
  /// Falls back to searching all offerings, then getProducts() as a last
  /// resort. Returns null if unavailable.
  Future<StoreProduct?> getBoostProduct() async {
    await _log(
      step: 'get_boost_product',
      status: 'start',
      productId: productId,
    );

    try {
      final offerings = await Purchases.getOfferings();

      await _log(
        step: 'get_boost_product',
        status: 'offerings_fetched',
        productId: productId,
        extraInfo:
            'offeringCount=${offerings.all.length}, currentOffering=${offerings.current?.identifier}',
      );

      // ── Step 1: Look in the dedicated 'boost' offering first ──────────────
      final boostOffering = offerings.getOffering(_offeringId);
      if (boostOffering != null) {
        Package? package;
        try {
          package = boostOffering.availablePackages.firstWhere(
            (p) => p.identifier == _packageId,
          );
        } catch (_) {
          // Package identifier not matched — fall back to first in offering.
          package = boostOffering.availablePackages.isNotEmpty
              ? boostOffering.availablePackages.first
              : null;
        }

        if (package != null) {
          _cachedPackage = package;
          await _log(
            step: 'get_boost_product',
            status: 'success',
            productId: productId,
            offeringId: _offeringId,
            extraInfo:
                'source=boost_offering, price=${package.storeProduct.priceString}',
          );
          return package.storeProduct;
        }
      }

      // ── Step 2: Search across all offerings ───────────────────────────────
      await _log(
        step: 'get_boost_product',
        status: 'boost_offering_not_found',
        productId: productId,
        extraInfo: 'falling back to searching all offerings',
      );

      for (final offering in offerings.all.values) {
        for (final package in offering.availablePackages) {
          if (package.storeProduct.identifier == productId) {
            _cachedPackage = package;
            await _log(
              step: 'get_boost_product',
              status: 'success',
              productId: productId,
              offeringId: offering.identifier,
              extraInfo:
                  'source=all_offerings_scan, price=${package.storeProduct.priceString}',
            );
            return package.storeProduct;
          }
        }
      }

      // ── Step 3: Last resort — getProducts() direct lookup ─────────────────
      await _log(
        step: 'get_boost_product',
        status: 'not_found_in_offerings',
        productId: productId,
        extraInfo: 'falling back to getProducts([productId])',
      );

      final products = await Purchases.getProducts([productId]);
      if (products.isNotEmpty) {
        await _log(
          step: 'get_boost_product',
          status: 'success',
          productId: productId,
          extraInfo:
              'source=getProducts, price=${products.first.priceString}',
        );
        return products.first;
      }

      await _log(
        step: 'get_boost_product',
        status: 'error',
        productId: productId,
        errorMessage: 'Product not found in offerings or getProducts',
      );
      await _logError(
        operationType: 'getBoostProduct',
        error: 'Product not found in offerings or getProducts',
        additionalData: {'productId': productId},
      );
      return null;
    } catch (e, st) {
      await _log(
        step: 'get_boost_product',
        status: 'error',
        productId: productId,
        errorMessage: e.toString(),
      );
      await _logError(
        operationType: 'getBoostProduct',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  // ─── Purchase + Apply Boost ──────────────────────────────────────────────

  /// Purchases the boost product and, on success, marks [postId] as boosted
  /// in Supabase. Returns true if the post was successfully boosted.
  ///
  /// Throws on unexpected errors (other than user cancellation, which
  /// returns false silently).
  Future<bool> buyBoost({
    required String postId,
    required StoreProduct product,
  }) async {
    await _log(
      step: 'buy_boost',
      status: 'start',
      productId: product.identifier,
      extraInfo: 'postId=$postId, price=${product.priceString}',
    );

    try {
      CustomerInfo customerInfo;

      if (_cachedPackage != null) {
        // Preferred: purchase via package (RevenueCat recommendation).
        customerInfo = await Purchases.purchasePackage(_cachedPackage!);
      } else {
        // Fallback: purchase directly by product.
        customerInfo = await Purchases.purchaseStoreProduct(product);
      }

      await _log(
        step: 'buy_boost_purchase',
        status: 'success',
        productId: product.identifier,
        extraInfo:
            'postId=$postId, activeEntitlements=${customerInfo.entitlements.active.keys.join(",")}',
      );

      // Consumables don't create entitlements — a non-error response means
      // the transaction completed successfully; apply the boost immediately.
      final applied = await _applyBoost(postId);

      if (!applied) {
        await _log(
          step: 'buy_boost',
          status: 'error',
          productId: product.identifier,
          errorMessage:
              'Purchase succeeded but failed to apply boost to post',
          extraInfo: 'postId=$postId',
        );
        await _logError(
          operationType: 'buyBoost_applyFailed',
          error: 'Purchase succeeded but failed to update post',
          additionalData: {
            'postId': postId,
            'productId': product.identifier,
          },
        );
      } else {
        await _log(
          step: 'buy_boost',
          status: 'success',
          productId: product.identifier,
          extraInfo: 'postId=$postId',
        );
      }

      return applied;
    } on PurchasesErrorCode catch (e, st) {
      if (e == PurchasesErrorCode.purchaseCancelledError) {
        await _log(
          step: 'buy_boost',
          status: 'cancelled',
          productId: product.identifier,
          errorCode: e.toString(),
          extraInfo: 'postId=$postId',
        );
        return false; // Not an error – do not log to purchase_errors.
      }
      await _log(
        step: 'buy_boost',
        status: 'error',
        productId: product.identifier,
        errorMessage: e.toString(),
        errorCode: e.toString(),
        extraInfo: 'postId=$postId',
      );
      await _logError(
        operationType: 'buyBoost',
        error: e,
        stackTrace: st,
        additionalData: {'postId': postId, 'productId': product.identifier},
      );
      rethrow;
    } catch (e, st) {
      await _log(
        step: 'buy_boost',
        status: 'error',
        productId: product.identifier,
        errorMessage: e.toString(),
        extraInfo: 'postId=$postId',
      );
      await _logError(
        operationType: 'buyBoost',
        error: e,
        stackTrace: st,
        additionalData: {'postId': postId, 'productId': product.identifier},
      );
      rethrow;
    }
  }

  // ─── Apply Boost ─────────────────────────────────────────────────────────

  /// Marks the given post as boosted: sets is_boosted = true and records
  /// the reaction-count target at which the boost should expire
  /// (current ratingsCount + [targetNewReactions]).
  Future<bool> _applyBoost(String postId) async {
    await _log(
      step: 'apply_boost',
      status: 'start',
      extraInfo: 'postId=$postId',
    );

    try {
      // Fetch current ratingsCount to calculate the expiry target.
      final post = await _supabase
          .from('posts')
          .select('ratingsCount')
          .eq('postId', postId)
          .maybeSingle();

      if (post == null) {
        await _log(
          step: 'apply_boost',
          status: 'error',
          errorMessage: 'Post not found',
          extraInfo: 'postId=$postId',
        );
        await _logError(
          operationType: '_applyBoost',
          error: 'Post not found',
          additionalData: {'postId': postId},
        );
        return false;
      }

      final int currentRatings =
          (post['ratingsCount'] as num?)?.toInt() ?? 0;
      final int target = currentRatings + targetNewReactions;

      await _log(
        step: 'apply_boost',
        status: 'fetched_post',
        extraInfo:
            'postId=$postId, currentRatings=$currentRatings, target=$target',
      );

      await _supabase.from('posts').update({
        'is_boosted': true,
        'boost_reactions_target': target,
      }).eq('postId', postId);

      await _log(
        step: 'apply_boost',
        status: 'success',
        extraInfo:
            'postId=$postId, targetRatingsCount=$target',
      );

      return true;
    } catch (e, st) {
      await _log(
        step: 'apply_boost',
        status: 'error',
        errorMessage: e.toString(),
        extraInfo: 'postId=$postId',
      );
      await _logError(
        operationType: '_applyBoost',
        error: e,
        stackTrace: st,
        additionalData: {'postId': postId},
      );
      return false;
    }
  }

  // ─── Status check ────────────────────────────────────────────────────────

  /// Returns the current boost status for a post, or null on error.
  Future<bool?> isPostBoosted(String postId) async {
    await _log(
      step: 'is_post_boosted',
      status: 'start',
      extraInfo: 'postId=$postId',
    );

    try {
      final row = await _supabase
          .from('posts')
          .select('is_boosted')
          .eq('postId', postId)
          .maybeSingle();

      final result = (row?['is_boosted'] as bool?) ?? false;

      await _log(
        step: 'is_post_boosted',
        status: 'success',
        extraInfo: 'postId=$postId, isBoosted=$result',
      );

      return result;
    } catch (e, st) {
      await _log(
        step: 'is_post_boosted',
        status: 'error',
        errorMessage: e.toString(),
        extraInfo: 'postId=$postId',
      );
      await _logError(
        operationType: 'isPostBoosted',
        error: e,
        stackTrace: st,
        additionalData: {'postId': postId},
      );
      return null;
    }
  }
}
