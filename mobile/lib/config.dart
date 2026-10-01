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

/// Clé Google Maps Platform (Map Tiles API, Places API (New), Geocoding API).
///
/// Lue à la compilation : `flutter build apk --dart-define=GOOGLE_MAPS_API_KEY=...`
/// Sans clé, la carte utilise automatiquement OpenStreetMap + Nominatim.
/// Dans Google Cloud, restreindre la clé aux applications Android
/// (package [androidPackageName] + empreinte SHA-1 du certificat de signature)
/// et aux 3 API ci-dessus.
const String googleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

bool get hasGoogleMapsKey => googleMapsApiKey.isNotEmpty;

/// Identifiant Android de l'app (applicationId de android/app/build.gradle.kts).
/// Envoyé dans l'en-tête `X-Android-Package` des appels Google (clé restreinte Android).
const String androidPackageName = 'com.ivrivrii.ivrivrii_chicken';

/// Empreinte SHA-1 du certificat de signature (ex. `AB:CD:...`), facultative :
/// `--dart-define=GOOGLE_ANDROID_CERT_SHA1=...`. Envoyée dans `X-Android-Cert`,
/// nécessaire pour qu'une clé restreinte « applications Android » accepte les appels REST.
const String googleAndroidCertSha1 = String.fromEnvironment('GOOGLE_ANDROID_CERT_SHA1');
