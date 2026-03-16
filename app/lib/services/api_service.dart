import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class ApiService {
  static String get baseUrl {
    // Android emulator uses 10.0.2.2 to reach host machine
    // Physical devices need the actual local IP or a deployed URL
    if (kIsWeb) return 'http://localhost:3005';
    if (Platform.isAndroid) {
      // Change to your machine's local IP for physical device testing:
      // return 'http://192.168.x.x:3005';
      return 'http://10.0.2.2:3005';
    }
    return 'http://localhost:3005';
  }

  String? _authToken;

  void setAuthToken(String token) {
    _authToken = token;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      };

  // Auth
  Future<Map<String, dynamic>> login() async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers,
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> getMe() async {
    final response = await http.get(
      Uri.parse('$baseUrl/auth/me'),
      headers: _headers,
    );
    return jsonDecode(response.body);
  }

  // Territories
  Future<Map<String, dynamic>> claimTerritory(List<LatLng> coordinates) async {
    final coords = coordinates
        .map((c) => [c.longitude, c.latitude])
        .toList();

    final response = await http.post(
      Uri.parse('$baseUrl/territories/claim'),
      headers: _headers,
      body: jsonEncode({'coordinates': coords}),
    );
    return jsonDecode(response.body);
  }

  Future<List<dynamic>> getTerritories({String? regionId}) async {
    final uri = Uri.parse('$baseUrl/territories').replace(
      queryParameters: regionId != null ? {'region_id': regionId} : null,
    );
    final response = await http.get(uri, headers: _headers);
    final data = jsonDecode(response.body);
    return data['territories'] ?? [];
  }

  Future<List<dynamic>> getMyTerritories() async {
    final response = await http.get(
      Uri.parse('$baseUrl/territories/mine'),
      headers: _headers,
    );
    final data = jsonDecode(response.body);
    return data['territories'] ?? [];
  }

  // Rankings
  Future<List<dynamic>> getRankings(String regionId, {int limit = 50}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/rankings/$regionId?limit=$limit'),
      headers: _headers,
    );
    final data = jsonDecode(response.body);
    return data['rankings'] ?? [];
  }

  Future<List<dynamic>> getNearbyRegions(double lat, double lng) async {
    final response = await http.get(
      Uri.parse('$baseUrl/rankings/regions/nearby?lat=$lat&lng=$lng'),
      headers: _headers,
    );
    final data = jsonDecode(response.body);
    return data['regions'] ?? [];
  }
}
