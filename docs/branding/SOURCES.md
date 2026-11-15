# Argo brand assets

The artwork is the Argo project owner's existing green-and-ink cube mark. The original SVG is preserved byte-for-byte as [argo-logo.svg](argo-logo.svg), SHA-256 `e790a1ac6573df01d882f860bf43e8af63006a9a3ddcb8b0fb66a8894f4bbaee`. The original SVG carries no separate author/year or license notice; its reuse here follows the owner's task authorization. UI dependency copyright notices remain in their original licenses.

The colors remain `#C4D9B3` and `#1A2D36`, and the three cube paths and their transform remain unchanged.

| File | Use |
| --- | --- |
| [argo-logo.svg](argo-logo.svg) | Original scalable source, including its rounded tile |
| [argo-logo.png](argo-logo.png) | Original 1024×1024 transparent-corner PNG, preserved byte-for-byte for README and rebuilds |
| [argo-appicon.svg](argo-appicon.svg) | Same mark with an opaque square background for the iOS system mask |
| `ios/Argo/Resources/Assets.xcassets/AppIcon.appiconset/Argo.png` | 1024×1024, 8-bit RGB iOS AppIcon |
| `ios/Argo/Resources/Assets.xcassets/ArgoMark.imageset/Argo.png` | Same RGB image for the in-app brand mark |

The original PNG has SHA-256 `94d9090c2deeda43455ec280a469e8c5f25a63abdea8d02c85c1aebcc3c3bee1`. It is already 1024×1024, so the README uses the original export and the iOS icon fills its transparent corners with the original background color. No resizing, tracing or sharpening is applied. iOS applies its own corner mask. The README displays its PNG at 144 points; both vectors remain available for other sizes.

Rebuild from the repository root with Python 3 and ImageMagick 6 (`convert`):

```sh
python3 scripts/rebuild-branding.py
```

For an isolated comparison, pass `--output-root <directory>`. The script uses ImageMagick's PNG reader and alpha compositing, and writes only the declared logo/icon outputs under that directory. ImageMagick is capped at two threads. Metadata is stripped from derived icons; different ImageMagick versions may change PNG compression.

Persona, BeautifulUI and Beautiful UI retain their original MIT license texts and notices. Links are in the [README](../../README.md#credits-and-licenses).
