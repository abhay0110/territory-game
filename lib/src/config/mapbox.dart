// NOTE: The Mapbox PUBLIC token (pk.*) is safe to ship in client builds — it is
// designed for client-side use and is rate-limited per your Mapbox account.
// `--dart-define=MAPBOX_ACCESS_TOKEN=…` still wins if provided, otherwise the
// hardcoded default keeps debug + release builds aligned.
const String kMapboxAccessToken = String.fromEnvironment(
  'MAPBOX_ACCESS_TOKEN',
  defaultValue:
      'pk.eyJ1IjoiYWJoYXkwMTEwIiwiYSI6ImNtbWIxcWgwYzBrMzIyb29ob3E3Nnl4cGQifQ.2NJDbC_Labl7eMFSvq_7nQ',
);

const String kMapboxDarkStyleUri = 'mapbox://styles/mapbox/dark-v11';