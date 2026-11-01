import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart';

/// Data model for a single vector memory unit.
class VectorMemory {
  final String id;
  final String text; // the memory's original text
  final List<double> vector; // the multi-dimensional vector for the text
  final int timestamp;

  VectorMemory({
    required this.id,
    required this.text,
    required this.vector,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'vector': vector,
    'timestamp': timestamp,
  };

  factory VectorMemory.fromJson(Map<String, dynamic> json) {
    return VectorMemory(
      id: json['id'],
      text: json['text'],
      vector: List<double>.from(json['vector'].map((x) => x.toDouble())),
      timestamp: json['timestamp'],
    );
  }
}

/// A lightweight local vector database implemented in pure Dart.
class VectorStore {
  static final VectorStore _instance = VectorStore._internal();
  factory VectorStore() => _instance;
  VectorStore._internal();

  static const String _prefsKey = 'agent_vector_memories';
  List<VectorMemory> _memories = [];
  bool _isInitialized = false;

  /// 🌟 1. Initialize and load the vector data from local disk.
  Future<void> init() async {
    if (_isInitialized) return;
    final prefs = await SharedPreferences.getInstance();
    final String? jsonString = prefs.getString(_prefsKey);

    if (jsonString != null) {
      final List<dynamic> decodedList = json.decode(jsonString);
      _memories = decodedList
          .map((item) => VectorMemory.fromJson(item))
          .toList();
    }

    _isInitialized = true;
    Log.i(
      '🌌 [VectorStore] Vector database mounted, currently holding ${_memories.length} high-dimensional memory fragments.',
    );
  }

  /// 🌟 2. Store a new memory vector.
  Future<void> addMemory(String text, List<double> vector) async {
    final newMemory = VectorMemory(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      vector: vector,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );

    _memories.add(newMemory);
    await _saveToDisk();
    Log.i('💾 [VectorStore] Wrote new vector memory: $text');
  }

  /// 🌟 3. Semantic search (core RAG logic: find the most similar Top-K memories).
  List<String> search(List<double> queryVector, {int topK = 3}) {
    if (_memories.isEmpty) return [];

    // Compute the similarity score of every memory against the query vector.
    List<Map<String, dynamic>> scoredMemories = [];
    for (var memory in _memories) {
      double score = _cosineSimilarity(queryVector, memory.vector);
      scoredMemories.add({'text': memory.text, 'score': score});
    }

    // Sort by similarity, high to low.
    scoredMemories.sort((a, b) => b['score'].compareTo(a['score']));

    // Take Top K, and only return memories above a similarity threshold (e.g. 0.7).
    List<String> results = [];
    for (int i = 0; i < min(topK, scoredMemories.length); i++) {
      if (scoredMemories[i]['score'] > 0.70) {
        results.add(scoredMemories[i]['text']);
      }
    }

    return results;
  }

  /// 🌟 4. Pure-Dart math engine: cosine similarity.
  /// Formula: A·B / (||A|| * ||B||)
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += pow(a[i], 2);
      normB += pow(b[i], 2);
    }

    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dotProduct / (sqrt(normA) * sqrt(normB));
  }

  /// Flush the in-memory vector array to disk.
  Future<void> _saveToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final String jsonString = json.encode(
      _memories.map((m) => m.toJson()).toList(),
    );
    await prefs.setString(_prefsKey, jsonString);
  }

  /// Clear the entire memory store.
  Future<void> clearAll() async {
    _memories.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    Log.i('🧹 [VectorStore] Vector memory store has been physically cleared');
  }
}
