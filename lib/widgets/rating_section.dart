import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';

class RatingSection extends StatefulWidget {
  final String postId;
  final String userId;
  final List<Map<String, dynamic>> ratings;
  final ValueChanged<double> onRatingEnd;
  final double? userRating; // user's own rating (if any)
  final String? userProfilePhoto; // user's profile photo URL

  const RatingSection({
    Key? key,
    required this.postId,
    required this.userId,
    required this.ratings,
    required this.onRatingEnd,
    this.userRating,
    this.userProfilePhoto,
  }) : super(key: key);

  @override
  State<RatingSection> createState() => _RatingSectionState();
}

class _RatingSectionState extends State<RatingSection> {
  double _averageRating = 0.0;
  String _reactionEmoji = '❤️';
  bool _isLoading = true;
  bool _hasUserRated = false; // whether current user has rated

  @override
  void initState() {
    super.initState();
    _computeAverageRatingAndUserRating();
    _fetchReactionEmoji();
  }

  void _computeAverageRatingAndUserRating() {
    if (widget.ratings.isEmpty) {
      _averageRating = 0.0;
      _hasUserRated = false;
      return;
    }
    double total = 0.0;
    int count = 0;
    bool userFound = false;
    for (final rating in widget.ratings) {
      final dynamic rUid =
          rating['userId'] ?? rating['userid'] ?? rating['user_id'];
      if (rUid != null && rUid.toString() == widget.userId) {
        userFound = true;
      }
      final dynamic rVal = rating['rating'] ?? rating['value'];
      if (rVal is num) {
        total += rVal.toDouble();
        count++;
      }
    }
    _averageRating = count > 0 ? total / count : 0.0;
    _hasUserRated = userFound;
  }

  Future<void> _fetchReactionEmoji() async {
    try {
      final response = await Supabase.instance.client
          .from('posts')
          .select('reaction_emoji')
          .eq('postId', widget.postId)
          .maybeSingle();
      if (mounted && response != null) {
        final emoji = response['reaction_emoji']?.toString();
        if (emoji != null && emoji.isNotEmpty) {
          setState(() => _reactionEmoji = emoji);
        }
      }
    } catch (_) {
      // keep default emoji
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox.shrink();
    }

    // If user has already rated, start thumb at community average.
    // Otherwise start at centre (5.0).
    final double initialPos = _hasUserRated ? _averageRating : 5.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4.0),
        RatingBar(
          averageRating: _averageRating,
          reactionEmoji: _reactionEmoji,
          initialThumbPosition: initialPos,
          onRatingEnd: (rating) async {
            final String response = await SupabasePostsMethods().ratePost(
              widget.postId,
              widget.userId,
              rating,
            );
            if (!mounted) return;
            if (response != 'success') {
              showSnackBar(context, response);
            } else {
              widget.onRatingEnd(rating);
            }
          },
          hasUserRated: _hasUserRated,
          userRating: widget.userRating,
          userProfilePhoto: widget.userProfilePhoto,
        ),
      ],
    );
  }
}
