class AgentMoment {
  int? id;

  String authorId;
  String authorNickname;
  String authorAvatar;

  String content;
  String? imageUrl;
  DateTime timestamp;

  /// List of userIds who liked this
  List<String> likes;
  List<MomentComment> comments;

  AgentMoment({
    this.id,
    required this.authorId,
    required this.authorNickname,
    required this.authorAvatar,
    required this.content,
    required this.timestamp,
    this.imageUrl,
    List<String>? likes,
    List<MomentComment>? comments,
  }) : likes = likes ?? <String>[],
       comments = comments ?? <MomentComment>[];

  Map<String, Object?> toJson() => {
    'authorId': authorId,
    'authorNickname': authorNickname,
    'authorAvatar': authorAvatar,
    'content': content,
    if (imageUrl != null) 'imageUrl': imageUrl,
    'timestamp': timestamp.toIso8601String(),
    'likes': likes,
    'comments': comments.map((c) => c.toJson()).toList(),
  };

  factory AgentMoment.fromJson(
    Map<String, Object?> json, {
    int? id,
  }) => AgentMoment(
    id: id,
    authorId: json['authorId'] as String? ?? '',
    authorNickname: json['authorNickname'] as String? ?? '',
    authorAvatar: json['authorAvatar'] as String? ?? '',
    content: json['content'] as String? ?? '',
    imageUrl: json['imageUrl'] as String?,
    timestamp:
        DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    likes:
        (json['likes'] as List?)?.map((e) => e.toString()).toList() ??
        <String>[],
    comments:
        (json['comments'] as List?)
            ?.map(
              (e) =>
                  MomentComment.fromJson(Map<String, Object?>.from(e as Map)),
            )
            .toList() ??
        <MomentComment>[],
  );
}

class MomentComment {
  String? userId;
  String? userNickname;
  String? content;
  DateTime? timestamp;

  MomentComment({this.userId, this.userNickname, this.content, this.timestamp});

  Map<String, Object?> toJson() => {
    if (userId != null) 'userId': userId,
    if (userNickname != null) 'userNickname': userNickname,
    if (content != null) 'content': content,
    if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
  };

  factory MomentComment.fromJson(Map<String, Object?> json) => MomentComment(
    userId: json['userId'] as String?,
    userNickname: json['userNickname'] as String?,
    content: json['content'] as String?,
    timestamp: json['timestamp'] is String
        ? DateTime.tryParse(json['timestamp'] as String)
        : null,
  );
}
