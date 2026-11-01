import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SpUtils {
  // 1. Private constructor to prevent instantiation
  SpUtils._();

  static SharedPreferences? _prefs;

  // 2. Initialization method
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Check if initialized
  static bool get isInitialized => _prefs != null;

  /// ----------------------------------------------------------
  /// Generic setter (Auto-detect type)
  /// ----------------------------------------------------------
  static Future<bool> put(String key, dynamic value) async {
    if (_prefs == null) return false;

    if (value == null) {
      return _prefs!.remove(key); // If value is null, treat as delete
    }

    if (value is String) return _prefs!.setString(key, value);
    if (value is bool) return _prefs!.setBool(key, value);
    if (value is int) return _prefs!.setInt(key, value);
    if (value is double) return _prefs!.setDouble(key, value);
    if (value is List<String>) return _prefs!.setStringList(key, value);

    // If it's a Map or object, auto-encode to JSON string for storage
    return _prefs!.setString(key, jsonEncode(value));
  }

  /// ----------------------------------------------------------
  /// Getters (support default values to avoid null safety issues)
  /// ----------------------------------------------------------

  static String getString(String key, {String defValue = ''}) {
    return _prefs?.getString(key) ?? defValue;
  }

  static bool getBool(String key, {bool defValue = false}) {
    return _prefs?.getBool(key) ?? defValue;
  }

  static int getInt(String key, {int defValue = 0}) {
    return _prefs?.getInt(key) ?? defValue;
  }

  static double getDouble(String key, {double defValue = 0.0}) {
    return _prefs?.getDouble(key) ?? defValue;
  }

  static List<String> getStringList(
    String key, {
    List<String> defValue = const [],
  }) {
    return _prefs?.getStringList(key) ?? defValue;
  }

  /// Get object (auto-deserialize JSON)
  static T? getObj<T>(
    String key,
    T Function(Map<String, dynamic> v) f, {
    T? defValue,
  }) {
    String? jsonStr = _prefs?.getString(key);
    if (jsonStr == null || jsonStr.isEmpty) return defValue;
    try {
      Map<String, dynamic> map = jsonDecode(jsonStr);
      return f(map);
    } catch (e) {
      return defValue;
    }
  }

  /// ----------------------------------------------------------
  /// Utility methods
  /// ----------------------------------------------------------

  // Check if key exists
  static bool hasKey(String key) {
    return _prefs?.containsKey(key) ?? false;
  }

  // Remove key
  static Future<bool> remove(String key) async {
    return await _prefs?.remove(key) ?? false;
  }

  // Clear all
  static Future<bool> clear() async {
    return await _prefs?.clear() ?? false;
  }
}
