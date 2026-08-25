import Foundation

/// SVG markup used by the preview fixtures and the flattener tests.
///
/// Kept as real, hand-written markup rather than generated strings so the tests exercise the parser
/// on the constructs that actually appear in icon sets: groups with transforms, `defs` gradients
/// referenced by `url(#id)`, stroke-only paths, `viewBox` scaling, and text.
public enum AnimatedPreviewSVG {
    /// Four stroke-only subpaths, which is what makes it a good draw-on subject: the outline, two
    /// eyes, and a mouth draw one after another under `staggerSeconds`.
    public static let strokeFace = """
    <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" \
    fill="none" stroke="#1B1B2F" stroke-width="6" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="50" cy="50" r="38"/>
      <path d="M36 41 L36 48"/>
      <path d="M64 41 L64 48"/>
      <path d="M33 61 Q50 76 67 61"/>
    </svg>
    """

    /// A single continuous stroke, for the simplest possible draw-on.
    public static let strokeCheck = """
    <svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" \
    fill="none" stroke="#26C281" stroke-width="10" stroke-linecap="round" stroke-linejoin="round">
      <path d="M22 53 L42 72 L78 30"/>
    </svg>
    """

    /// Gradients in `defs`, a group transform, nested shapes, and a `polygon` — the constructs a
    /// flattener is most likely to get wrong.
    public static let gradientBadge = """
    <svg viewBox="0 0 120 120" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#7C5CFF"/>
          <stop offset="1" stop-color="#FF6BA9"/>
        </linearGradient>
        <radialGradient id="glow" cx="0.5" cy="0.42" r="0.55">
          <stop offset="0" stop-color="#FFF7D6"/>
          <stop offset="1" stop-color="#FFD166"/>
        </radialGradient>
      </defs>
      <rect x="6" y="6" width="108" height="108" rx="26" fill="url(#sky)"/>
      <circle cx="60" cy="52" r="26" fill="url(#glow)"/>
      <g transform="translate(60 60) rotate(12)">
        <polygon points="0,-30 8.8,-9.3 31,-9.3 13,4 20,26 0,13 -20,26 -13,4 -31,-9.3 -8.8,-9.3" \
    fill="#FFFFFF" fill-opacity="0.92"/>
      </g>
      <rect x="26" y="96" width="68" height="6" rx="3" fill="#FFFFFF" fill-opacity="0.55"/>
    </svg>
    """

    /// Contains a `<text>` node, which cannot be flattened to a path and exercises the passthrough
    /// branch: it is drawn natively in paint order and ignores trim.
    public static let textBadge = """
    <svg viewBox="0 0 140 60" xmlns="http://www.w3.org/2000/svg">
      <rect x="2" y="2" width="136" height="56" rx="14" fill="#1B1B2F"/>
      <circle cx="30" cy="30" r="12" fill="#FFD166"/>
      <text x="52" y="38" font-family="Helvetica" font-size="22" fill="#FFFFFF">NEW</text>
    </svg>
    """

    /// A bare `d` string for `AnimatedShapeKind.path`, in its own arbitrary coordinate space to
    /// prove the shape is refitted into the layer box rather than assumed to be 0–1 or 0–100.
    public static let boltPathData = "M 312 40 L 180 232 L 288 232 L 240 400 L 372 208 L 264 208 Z"

    /// A long, curvy, single-subpath signature — the clearest demonstration of draw-on.
    public static let signaturePathData = """
    M 10 60 C 24 20, 44 20, 52 52 C 58 76, 70 78, 78 56 C 86 34, 104 34, 112 60 \
    C 120 86, 138 86, 150 56
    """
}
