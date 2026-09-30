/// Adresse de l'API.
///
/// Par défaut `10.0.2.2` pointe vers le PC depuis l'émulateur Android.
/// Sur un vrai téléphone, lancez avec l'IP du PC sur le réseau Wi-Fi :
///   flutter run --dart-define=API_URL=http://192.168.1.20:4000
const String apiBaseUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://10.0.2.2:4000',
);

/// Transforme un chemin relatif (`/uploads/...`) renvoyé par l'API en URL complète.
String resolveImageUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  if (url.startsWith('http')) return url;
  return '$apiBaseUrl$url';
}
