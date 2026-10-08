import 'package:aves/services/security_service.dart';

class FakeSecurityService implements SecurityService {
  final Map<String, Object?> _values = {};

  @override
  Future<T?> readValue<T>(String key) async => _values[key] as T?;

  @override
  Future<bool> writeValue<T>(String key, T? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    return true;
  }
}
