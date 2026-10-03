import Foundation

/// Quartz Composer's colour arithmetic, measured from the 4.6.2 framework.
///
/// Nothing here comes from documentation. Each rule was read back from a live patch
/// instance through `qcgather` (`QCColorFromComponents`, `QCColorToComponents`,
/// `QCColorTransform`, `QCColorMixer`) and every value is pinned by `QCColorPatchTests`.
///
/// Two details are easy to get wrong, and both were settled by probing rather than by
/// assuming:
///
/// * `Color Transformation`'s **Hue Rotation is in degrees**, not a 0…1 fraction. On pure
///   red, 30 yields orange and 240 yields blue; 0.25 is a quarter of a degree and visibly
///   changes nothing.
/// * Its colour factors work on **HSL components, not on the raw RGB channels**. The
///   saturation factor scales HSL saturation and the luminosity factor scales HSL
///   luminosity. A luminosity factor of 2 on `(0.5, 0.25, 0.75)` therefore gives white, not
///   the `(1, 0.5, 1)` that scaling each channel would give. The two agree for factors at or
///   below 1 and diverge above them, so a probe at 0.5 will not catch this.
///
/// Hue rotation preserves both the luminosity and the saturation, and the saturation and
/// luminosity factors act on independent HSL components, so the transformations commute:
/// their order is not observable.
enum QCColorMath {
    struct RGBA: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    struct HSL: Hashable, Sendable {
        var hue: Double
        var saturation: Double
        var luminosity: Double
    }

    static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    // MARK: - Component conversion

    /// RGB → HSL, the conversion behind `Color to HSL`.
    ///
    /// Achromatic colours report hue and saturation as 0, which is what the framework
    /// returns for black (`0, 0, 0`) and white (`0, 0, 1`). Hue is normalised to `0..<1`.
    static func hsl(from color: RGBA) -> HSL {
        let highest = max(color.red, max(color.green, color.blue))
        let lowest = min(color.red, min(color.green, color.blue))
        let luminosity = (highest + lowest) / 2
        let delta = highest - lowest

        guard delta > 0 else {
            return HSL(hue: 0, saturation: 0, luminosity: luminosity)
        }

        let saturation = delta / (1 - abs(2 * luminosity - 1))
        let hue: Double
        if highest == color.red {
            hue = (color.green - color.blue) / delta
        } else if highest == color.green {
            hue = (color.blue - color.red) / delta + 2
        } else {
            hue = (color.red - color.green) / delta + 4
        }
        return HSL(
            hue: normalizeHue(hue / 6),
            saturation: saturation,
            luminosity: luminosity
        )
    }

    /// HSL → RGB, the conversion behind `Color to RGB`'s sibling `HSL Color`.
    static func rgba(from hsl: HSL, alpha: Double) -> RGBA {
        let saturation = clamp(hsl.saturation)
        let luminosity = clamp(hsl.luminosity)
        let chroma = (1 - abs(2 * luminosity - 1)) * saturation
        let section = normalizeHue(hsl.hue) * 6
        let second = chroma * (1 - abs(section.truncatingRemainder(dividingBy: 2) - 1))
        let match = luminosity - chroma / 2

        let (red, green, blue): (Double, Double, Double)
        switch section {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        return RGBA(
            red: clamp(red + match),
            green: clamp(green + match),
            blue: clamp(blue + match),
            alpha: clamp(alpha)
        )
    }

    private static func normalizeHue(_ hue: Double) -> Double {
        let wrapped = hue - floor(hue)
        return wrapped == 1 ? 0 : wrapped
    }

    // MARK: - Color Transformation

    /// Applies `Color Transformation` to a colour.
    ///
    /// All three colour factors are **HSL-space scalings**, each clamped to its own range:
    /// hue is rotated by degrees, saturation is multiplied and clamped to `0...1`, and
    /// luminosity is multiplied and clamped to `0...1`. Alpha is a plain clamped multiply.
    /// Because hue rotation leaves both S and L alone, and S and L scale independently, the
    /// operations commute and their order is not observable.
    ///
    /// Scaling HSL luminosity rather than the raw components is the subtle part: on
    /// `(0.5, 0.25, 0.75)` a factor of 2 gives white, not `(1, 0.5, 1)`, and on `(1, 1, 0)`
    /// a factor of 1.5 gives `(1, 1, 0.5)`, not `(1, 1, 0)`.
    ///
    /// The saturation factor is *not* a scale about the component mean either: on
    /// `(1, 1, 0)` a factor of 0.5 gives `(0.75, 0.75, 0.25)`, which is the HSL form; the
    /// mean would give `(0.833, 0.833, 0.333)`.
    static func transform(
        _ color: RGBA,
        hueRotation: Double,
        saturation: Double,
        luminosity: Double,
        alpha: Double
    ) -> RGBA {
        let alpha = alpha == 1 ? color.alpha : clamp(color.alpha * alpha)

        // Identity factors must not round-trip through HSL, which would perturb the input.
        guard hueRotation != 0 || saturation != 1 || luminosity != 1 else {
            return RGBA(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
        }

        var hsl = hsl(from: color)
        if hueRotation != 0 {
            hsl.hue = normalizeHue(hsl.hue + hueRotation / 360)
        }
        if saturation != 1 {
            hsl.saturation = clamp(hsl.saturation * saturation)
        }
        if luminosity != 1 {
            hsl.luminosity = clamp(hsl.luminosity * luminosity)
        }
        return rgba(from: hsl, alpha: alpha)
    }

    // MARK: - Color Mixer

    /// The `Interpolation` menu of `Color Mixer`, in index order.
    ///
    /// The framework's menu attribute also carries `"-"` separator entries. Those are
    /// display-only and do not occupy an index, which is why `Cubic Out` is index 5 and not
    /// 7: an off-by-two here silently selects the wrong easing curve.
    static let mixerInterpolations = [
        "Linear",
        "Quadratic In", "Quadratic Out", "Quadratic In-Out",
        "Cubic In", "Cubic Out", "Cubic In-Out",
        "Exponential In", "Exponential Out", "Exponential In-Out",
        "Sinusoidal In", "Sinusoidal Out", "Sinusoidal In-Out",
    ]

    private static let mixerCurves: [String: String] = [
        "Linear": "linear",
        "Quadratic In": "quadratic-in",
        "Quadratic Out": "quadratic-out",
        "Quadratic In-Out": "quadratic-in-out",
        "Cubic In": "cubic-in",
        "Cubic Out": "cubic-out",
        "Cubic In-Out": "cubic-in-out",
        "Exponential In": "exponential-in",
        "Exponential Out": "exponential-out",
        "Exponential In-Out": "exponential-in-out",
        "Sinusoidal In": "sinusoidal-in",
        "Sinusoidal Out": "sinusoidal-out",
        "Sinusoidal In-Out": "sinusoidal-in-out",
    ]

    /// `Color Mixer`, which eases the mixing point and then interpolates every channel —
    /// alpha included — independently.
    static func mix(_ first: RGBA, _ second: RGBA, amount: Double, interpolation: String) -> RGBA {
        let amount = QCControlMath.curveProgress(
            amount,
            curve: mixerCurves[interpolation] ?? "linear"
        )
        return RGBA(
            red: first.red + (second.red - first.red) * amount,
            green: first.green + (second.green - first.green) * amount,
            blue: first.blue + (second.blue - first.blue) * amount,
            alpha: first.alpha + (second.alpha - first.alpha) * amount
        )
    }
}
