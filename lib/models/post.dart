class Post {
  final String? description;
  final String? gender;
  final String postId; // UUID
  final String? postUrl;
  final String? profImage;
  final String? uid;
  final String? username;
  final num? commentsCount; // Numeric type in PostgreSQL
  final DateTime? datePublished;
  final List<PostRating> ratings; // New field for ratings

  const Post({
    this.description,
    this.gender,
    required this.postId,
    this.postUrl,
    this.profImage,
    this.uid,
    this.username,
    this.commentsCount,
    this.datePublished,
    this.ratings = const [], // Initialize as empty list
  });

  factory Post.fromMap(Map<String, dynamic> data) {
    return Post(
      description: data["description"],
      gender: data["gender"],
      postId: data["postId"] ?? '', // UUID required
      postUrl: data["postUrl"],
      profImage: data["profImage"],
      uid: data["uid"],
      username: data["username"],
      commentsCount: data["commentsCount"] != null
          ? num.tryParse(data["commentsCount"].toString())
          : null,
      datePublished: data["datePublished"] != null
          ? DateTime.parse(data["datePublished"].toString())
          : null,
      // Ratings will be added separately
      ratings: [],
    );
  }

  Map<String, dynamic> toMap() => {
        "description": description,
        "gender": gender,
        "postId": postId,
        "postUrl": postUrl,
        "profImage": profImage,
        "uid": uid,
        "username": username,
        "commentsCount": commentsCount,
        "datePublished": datePublished?.toIso8601String(),
        // Ratings are stored separately in their own table
      };

  // Helper method to calculate average rating
  double get averageRating {
    if (ratings.isEmpty) return 0.0;
    final total = ratings.fold(0.0, (sum, rating) => sum + rating.rating);
    return total / ratings.length;
  }

  // Helper to find a user's rating
  PostRating? getUserRating(String userId) {
    try {
      return ratings.firstWhere((rating) => rating.userId == userId);
    } catch (e) {
      return null;
    }
  }
}

class PostRating {
  final String postId; // UUID
  final String userId;
  final double rating;
  final DateTime timestamp;

  const PostRating({
    required this.postId,
    required this.userId,
    required this.rating,
    required this.timestamp,
  });

  factory PostRating.fromMap(Map<String, dynamic> data) {
    return PostRating(
      postId: data["postid"] ?? '',
      userId: data["userid"] ?? '',
      rating: (data["rating"] as num?)?.toDouble() ?? 0.0,
      timestamp: data["timestamp"] != null
          ? DateTime.parse(data["timestamp"].toString())
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        "postid": postId,
        "userid": userId,
        "rating": rating,
        "timestamp": timestamp.toIso8601String(),
      };
}
