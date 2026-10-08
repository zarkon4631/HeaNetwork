Routing rule-sets (`*.srs`) bundled with the app live here. They are not kept
in git; `tool/fetch_assets.ps1` downloads them from the SagerNet `sing-geosite`
and `sing-geoip` repositories before a build.

The app works without them: the presets that use a missing rule-set fall back
to plain domain-suffix rules.
