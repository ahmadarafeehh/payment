// lib/resources/post_boost_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PostBoostService {
  static final PostBoostService _instance = PostBoostService._internal();
  factory PostBoostService() => _instance;
  PostBoostService._internal();

  static const String productId = 'boost_30';
  static const String _offeringId = 'boost';
  static const String _packageId = 'boost_package';
  static const int targetNewReactions = 30;

  Package? _cachedPackage;

  final SupabaseClient _supabase = Supabase.instance.client;

  String? get _firebaseUid => FirebaseAuth.instance.currentUser?.uid;

  // ─── Logging: purchase_logs ────────────────────────────────────────────────

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
    } catch (_) {}
  }

  // ─── Logging: purchase_errors ──────────────────────────────────────────────

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
    } catch (_) {}
  }

  // ─── Get Product ──────────────────────────────────────────────────────────

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

      // ── Step 1: dedicated 'boost' offering ────────────────────────────────
      final boostOffering = offerings.getOffering(_offeringId);
      if (boostOffering != null) {
        Package? package;
        try {
          package = boostOffering.availablePackages
              .firstWhere((p) => p.identifier == _packageId);
        } catch (_) {
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

      // ── Step 2: scan all offerings ─────────────────────────────────────────
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

      // ── Step 3: getProducts() direct lookup ────────────────────────────────
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
          extraInfo: 'source=getProducts, price=${products.first.priceString}',
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

  // ─── Purchase Only (no Supabase update) ───────────────────────────────────
  //
  // Used in the pre-post flow: user pays before the post exists.
  // Call applyBoost(postId) after the post is successfully uploaded.

  Future<bool> purchaseBoostOnly({required StoreProduct product}) async {
    await _log(
      step: 'purchase_boost_only',
      status: 'start',
      productId: product.identifier,
      extraInfo: 'price=${product.priceString}',
    );

    try {
      if (_cachedPackage != null) {
        await Purchases.purchasePackage(_cachedPackage!);
      } else {
        await Purchases.purchaseStoreProduct(product);
      }

      await _log(
        step: 'purchase_boost_only',
        status: 'success',
        productId: product.identifier,
      );
      return true;
    } on PurchasesErrorCode catch (e, st) {
      if (e == PurchasesErrorCode.purchaseCancelledError) {
        await _log(
          step: 'purchase_boost_only',
          status: 'cancelled',
          productId: product.identifier,
          errorCode: e.toString(),
        );
        return false;
      }
      await _log(
        step: 'purchase_boost_only',
        status: 'error',
        productId: product.identifier,
        errorMessage: e.toString(),
        errorCode: e.toString(),
      );
      await _logError(
        operationType: 'purchaseBoostOnly',
        error: e,
        stackTrace: st,
        additionalData: {'productId': product.identifier},
      );
      rethrow;
    } catch (e, st) {
      await _log(
        step: 'purchase_boost_only',
        status: 'error',
        productId: product.identifier,
        errorMessage: e.toString(),
      );
      await _logError(
        operationType: 'purchaseBoostOnly',
        error: e,
        stackTrace: st,
        additionalData: {'productId': product.identifier},
      );
      rethrow;
    }
  }

  // ─── Purchase + Apply (post already exists) ────────────────────────────────

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

    final purchased = await purchaseBoostOnly(product: product);
    if (!purchased) return false;

    final applied = await applyBoost(postId);

    if (!applied) {
      await _log(
        step: 'buy_boost',
        status: 'error',
        productId: product.identifier,
        errorMessage: 'Purchase succeeded but failed to apply boost to post',
        extraInfo: 'postId=$postId',
      );
      await _logError(
        operationType: 'buyBoost_applyFailed',
        error: 'Purchase succeeded but failed to update post',
        additionalData: {'postId': postId, 'productId': product.identifier},
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
  }

  // ─── Apply Boost (public — called after post upload in pre-post flow) ──────

  Future<bool> applyBoost(String postId) async {
    await _log(
      step: 'apply_boost',
      status: 'start',
      extraInfo: 'postId=$postId',
    );

    try {
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
          operationType: 'applyBoost',
          error: 'Post not found',
          additionalData: {'postId': postId},
        );
        return false;
      }

      final int currentRatings = (post['ratingsCount'] as num?)?.toInt() ?? 0;
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
        extraInfo: 'postId=$postId, targetRatingsCount=$target',
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
        operationType: 'applyBoost',
        error: e,
        stackTrace: st,
        additionalData: {'postId': postId},
      );
      return false;
    }
  }

  // ─── Status check ─────────────────────────────────────────────────────────

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
