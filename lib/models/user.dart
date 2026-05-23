class AppUser {
  final String uid;
  final String email;
  final String? username;
  final String? photoUrl;
  final String? bio;
  final bool? isPrivate;
  final bool? onboardingComplete;
  final DateTime? dateOfBirth;
  final DateTime? createdAt;
  final String? gender;
  final String? fcmToken;
  final List<String>? blockedUsers;
  final int? unreadCount;

  // Make these fields final
  final List<String> followers;
  final List<String> following;
  final List<String> followRequests;

  AppUser({
    required this.uid,
    required this.email,
    this.username,
    this.photoUrl,
    this.bio,
    this.isPrivate,
    this.onboardingComplete,
    this.dateOfBirth,
    this.createdAt,
    this.gender,
    this.fcmToken,
    this.blockedUsers,
    this.unreadCount,
    // Initialize relationships in constructor
    this.followers = const [],
    this.following = const [],
    this.followRequests = const [],
  });

  // Age is calculated from dateOfBirth
  int? get age {
    if (dateOfBirth == null) return null;
    final now = DateTime.now();
    int age = now.year - dateOfBirth!.year;
    if (now.month < dateOfBirth!.month ||
        (now.month == dateOfBirth!.month && now.day < dateOfBirth!.day)) {
      age--;
    }
    return age;
  }

  factory AppUser.fromMap(Map<String, dynamic> data) {
    return AppUser(
      uid: data['uid'] as String,
      email: data['email'] as String? ?? '',
      username: data['username'] as String?,
      photoUrl: data['photoUrl'] as String?,
      bio: data['bio'] as String?,
      isPrivate: data['isPrivate'] as bool? ?? false,
      onboardingComplete: data['onboardingComplete'] as bool? ?? false,
      dateOfBirth: data['dateOfBirth'] != null
          ? DateTime.parse(data['dateOfBirth'].toString())
          : null,
      createdAt: data['createdAt'] != null
          ? DateTime.parse(data['createdAt'].toString())
          : null,
      gender: data['gender'] as String?,
      fcmToken: data['fcmToken'] as String?,
      blockedUsers: _parseBlockedUsers(data['blockedUsers']),
      unreadCount: data['unreadCount'] != null
          ? int.tryParse(data['unreadCount'].toString())
          : null,
    );
  }

  static List<String>? _parseBlockedUsers(dynamic data) {
    if (data == null) return null;
    if (data is List) return data.cast<String>();
    return null;
  }

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'email': email,
        'username': username,
        'photoUrl': photoUrl,
        'bio': bio,
        'isPrivate': isPrivate,
        'onboardingComplete': onboardingComplete,
        'dateOfBirth': dateOfBirth?.toIso8601String(),
        'createdAt': createdAt?.toIso8601String(),
        'gender': gender,
        'fcmToken': fcmToken,
        'blockedUsers': blockedUsers,
        'unreadCount': unreadCount,
      };

  // Helper to add relationship data after initial creation
  AppUser withRelationships({
    List<String>? followers,
    List<String>? following,
    List<String>? followRequests,
  }) {
    return AppUser(
      uid: uid,
      email: email,
      username: username,
      photoUrl: photoUrl,
      bio: bio,
      isPrivate: isPrivate,
      onboardingComplete: onboardingComplete,
      dateOfBirth: dateOfBirth,
      createdAt: createdAt,
      gender: gender,
      fcmToken: fcmToken,
      blockedUsers: blockedUsers,
      unreadCount: unreadCount,
      followers: followers ?? this.followers,
      following: following ?? this.following,
      followRequests: followRequests ?? this.followRequests,
    );
  }
}
