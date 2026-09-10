# MacBridge logo

The user-provided blue MacBridge artwork is the single visual source of truth.
It is copied without redesign; smaller files are deterministic resizes of it.

- `macbridge-icon.png`: canonical 1254 × 1254 PNG with alpha.
- `MacBridge.icns`: Finder, Spotlight, Dock and application-switcher icon.
- `macbridge-icon-composer.png`: compact plugin/composer asset.
- `macbridge-icon-card.png`: 32 × 32 source embedded into the read-only activity card.

Recorded SHA-256 identities:

- Canonical PNG: `0f44186f16ac6e2d02d74b089fcc664f209c3d6a22931e528ed5cf33b905864d`
- ICNS: `0f595efa6ed24c1e50adcd32474b01caea842d7a2170027e8d515ade535f5f71`
- Composer PNG: `5811e806207818e0595f011c598c0c31141bdf3c1055bbd9c2567f91f72df9bc`
- Card PNG: `3f47df02cd171d9e6abc4f8125b7624d648df51ffdb6b21633601059fc2b0184`

The observer package installs the canonical PNG and ICNS in the app bundle. The
native header and running application use the PNG; macOS bundle surfaces use the
ICNS. The inline card contains the card-size PNG as a self-contained data URI,
with no asset server or network request.

The account-hosted ChatGPT connector icon is managed by the host. A local plugin
manifest can use `macbridge-icon-composer.png`, but changing this repository
cannot by itself replace an icon already cached or hosted by ChatGPT.
