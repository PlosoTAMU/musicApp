import SwiftUI
import UIKit

// MARK: - Theme
// Centralized design system for the entire app.
// Direction: red on black — a near-black "ink" base with hairline seams,
// a single vivid red accent for playback and primary actions, and a cooler
// rose reserved for queue/shuffle semantics. Typography is SF Rounded
// everywhere, with small tracked-uppercase "eyebrow" labels as the
// recurring structural device.
enum Theme {
    
    // MARK: Palette
    
    /// Base background. Near-black with a faint warm cast.  #0A0809
    static let ink = Color(red: 0.039, green: 0.031, blue: 0.035)
    /// Raised surface (cards, fields).  #17100F
    static let smoke = Color(red: 0.090, green: 0.063, blue: 0.059)
    /// Higher surface (placeholders, chips).  #211615
    static let smokeRaised = Color(red: 0.129, green: 0.086, blue: 0.082)
    /// Hairline stroke used on every surface.
    static let seam = Color.white.opacity(0.07)
    
    /// Primary text. Warm off-white.  #F4EDEA
    static let bone = Color(red: 0.957, green: 0.929, blue: 0.918)
    /// Secondary text.
    static let boneDim = bone.opacity(0.55)
    /// Tertiary text / inactive icons.
    static let boneFaint = bone.opacity(0.32)
    
    // Primary accent — red. Playback, progress, primary actions.
    /// Accent, light end.  #FF5E54
    static let redLight = Color(red: 1.0, green: 0.369, blue: 0.329)
    /// Accent, mid.  #F12B26
    static let red = Color(red: 0.945, green: 0.169, blue: 0.149)
    /// Accent, deep end.  #B91414
    static let redDeep = Color(red: 0.725, green: 0.078, blue: 0.078)
    
    /// Secondary accent — a cooler rose for queue / shuffle semantics so
    /// they stay distinguishable from the primary red.  #FF6B7D
    static let rose = Color(red: 1.0, green: 0.420, blue: 0.490)
    /// Destructive actions.  #FF6B6B
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
    
    static let redGradient = LinearGradient(
        colors: [redLight, redDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let roseGradient = LinearGradient(
        colors: [rose, Color(red: 0.78, green: 0.20, blue: 0.29)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // Backward-compatible aliases. The earlier "Afterhours" build used
    // ember/mint names throughout the view files; they now resolve to the
    // red/rose palette so those files keep compiling without edits.
    static let emberLight = redLight
    static let ember = red
    static let emberDeep = redDeep
    static let emberGradient = redGradient
    static let mint = rose
    static let mintGradient = roseGradient
    
    // MARK: Typography (SF Rounded throughout)
    
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }
    
    static func title(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    
    static func body(_ size: CGFloat = 16, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    
    static func caption(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    
    /// Small tracked-uppercase label font. Pair with `.tracking(1.5)`.
    static let eyebrowFont: Font = .system(size: 11, weight: .semibold, design: .rounded)
    
    // MARK: UIKit chrome (navigation + tab bars)
    
    /// Applies the theme to UIKit-backed chrome. Call once, early
    /// (e.g. in ContentView's init).
    static func applyChrome() {
        // Navigation bar
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(ink)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [
            .foregroundColor: UIColor(bone),
            .font: roundedUIFont(size: 17, weight: .bold)
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: UIColor(bone),
            .font: roundedUIFont(size: 34, weight: .heavy)
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = UIColor(emberLight)
        
        // Tab bar
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(ink)
        tab.shadowColor = UIColor(Color.white.opacity(0.08))
        
        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(boneFaint)
        item.normal.titleTextAttributes = [
            .foregroundColor: UIColor(boneFaint),
            .font: roundedUIFont(size: 10, weight: .semibold)
        ]
        item.selected.iconColor = UIColor(emberLight)
        item.selected.titleTextAttributes = [
            .foregroundColor: UIColor(emberLight),
            .font: roundedUIFont(size: 10, weight: .semibold)
        ]
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item
        
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
    
    static func roundedUIFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - App background

/// The shared screen background: ink base with two very faint red glows so
/// large empty areas don't read as flat black.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.ink
            RadialGradient(
                colors: [Theme.red.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [Theme.redDeep.opacity(0.13), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Surface card

struct SurfaceCardModifier: ViewModifier {
    var corner: CGFloat
    
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.smoke)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.seam, lineWidth: 1)
            )
    }
}

extension View {
    /// Wraps the view in the standard raised surface: smoke fill + seam hairline.
    func surfaceCard(corner: CGFloat = 16) -> some View {
        modifier(SurfaceCardModifier(corner: corner))
    }
}

// MARK: - Section eyebrow

/// The recurring structural device: a small ember tick followed by a
/// tracked-uppercase label. Used as every section header in the app.
struct SectionEyebrow: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.ember)
                .frame(width: 3, height: 11)
            Text(text.uppercased())
                .font(Theme.eyebrowFont)
                .tracking(1.5)
                .foregroundColor(Theme.boneDim)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - EQ indicator

/// Three animated capsules shown beside the track that is currently playing.
struct EQIndicator: View {
    var color: Color = Theme.emberLight
    @State private var animating = false
    
    private let peaks: [CGFloat] = [0.5, 1.0, 0.68]
    
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: 14)
                    .scaleEffect(y: animating ? peaks[index] : 0.25, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.13),
                        value: animating
                    )
            }
        }
        .frame(width: 14, height: 14)
        .onAppear { animating = true }
    }
}

// MARK: - Search field

struct ThemedSearchField: View {
    let placeholder: String
    @Binding var text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.boneFaint)
            
            TextField(
                "",
                text: $text,
                prompt: Text(placeholder)
                    .font(Theme.body(15))
                    .foregroundColor(Theme.boneFaint)
            )
            .font(Theme.body(15))
            .foregroundColor(Theme.bone)
            .autocorrectionDisabled()
            
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.boneFaint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.smoke))
        .overlay(Capsule().strokeBorder(Theme.seam, lineWidth: 1))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.smokeRaised)
                    .frame(width: 84, height: 84)
                    .overlay(Circle().strokeBorder(Theme.seam, lineWidth: 1))
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(Theme.boneFaint)
            }
            Text(title)
                .font(Theme.title(19))
                .foregroundColor(Theme.bone)
            Text(message)
                .font(Theme.body(14))
                .foregroundColor(Theme.boneDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
    }
}

// MARK: - Source chip

/// Tiny capsule showing where a track came from (YouTube / Spotify / Files).
struct SourceChip: View {
    let source: DownloadSource
    
    private var icon: String {
        switch source {
        case .youtube: return "play.rectangle.fill"
        case .spotify: return "music.note"
        case .folder: return "folder.fill"
        }
    }
    
    private var label: String {
        switch source {
        case .youtube: return "YouTube"
        case .spotify: return "Spotify"
        case .folder: return "Files"
        }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(Theme.caption(10, weight: .semibold))
        }
        .foregroundColor(Theme.boneDim)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.smokeRaised))
        .overlay(Capsule().strokeBorder(Theme.seam, lineWidth: 1))
    }
}

// MARK: - Shared artwork helpers

/// Shared thumbnail-path and background-art logic so MiniPlayerBar and
/// NowPlayingView no longer carry duplicate copies of it.
enum Artwork {
    
    private static let thumbnailsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()
    
    /// Thumbnail file URL for a given audio file URL
    /// (Thumbnails/<audio filename>.jpg).
    static func thumbnailURL(forAudioFileURL audioURL: URL) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(audioURL.lastPathComponent).jpg")
    }
    
    /// Loads the raw thumbnail image for an audio file, if one exists on disk.
    static func image(forAudioFileURL audioURL: URL) -> UIImage? {
        let path = thumbnailURL(forAudioFileURL: audioURL).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return UIImage(contentsOfFile: path)
    }
    
    /// Loads the thumbnail and center-crops it to the given aspect ratio
    /// (width / height). Used for the blurred backgrounds behind the mini
    /// player (wide) and the Now Playing screen (screen aspect).
    static func croppedBackground(forAudioFileURL audioURL: URL, aspect: CGFloat) -> UIImage? {
        guard let original = image(forAudioFileURL: audioURL) else { return nil }
        return crop(original, aspect: aspect)
    }
    
    /// Same crop, but from an explicit on-disk thumbnail path.
    static func croppedBackground(atPath path: String, aspect: CGFloat) -> UIImage? {
        guard FileManager.default.fileExists(atPath: path),
              let original = UIImage(contentsOfFile: path) else { return nil }
        return crop(original, aspect: aspect)
    }
    
    private static func crop(_ original: UIImage, aspect: CGFloat) -> UIImage {
        let imageAspect = original.size.width / original.size.height
        let cropRect: CGRect
        
        if imageAspect > aspect {
            let newWidth = original.size.height * aspect
            let x = (original.size.width - newWidth) / 2
            cropRect = CGRect(x: x, y: 0, width: newWidth, height: original.size.height)
        } else {
            let newHeight = original.size.width / aspect
            let y = (original.size.height - newHeight) / 2
            cropRect = CGRect(x: 0, y: y, width: original.size.width, height: newHeight)
        }
        
        guard let cropped = original.cgImage?.cropping(to: cropRect) else { return original }
        return UIImage(cgImage: cropped)
    }
}

// MARK: - Custom button styles

/// Circular transport / chrome button. Smoke-raised disc with a seam
/// hairline, optional red fill for the active state, and a press spring.
/// Replaces the default iOS button look across the player.
struct CircleControlButtonStyle: ButtonStyle {
    var diameter: CGFloat = 46
    var tint: Color = Theme.bone
    var filled: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(filled ? AnyShapeStyle(Theme.redGradient) : AnyShapeStyle(Theme.smokeRaised))
            )
            .overlay(
                Circle().strokeBorder(filled ? Color.white.opacity(0.18) : Theme.seam, lineWidth: 1)
            )
            .shadow(color: filled ? Theme.red.opacity(0.5) : .clear,
                    radius: filled ? 10 : 0, y: filled ? 3 : 0)
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The primary play/pause button: a red gradient disc with a glow and a
/// press spring.
struct PlayButtonStyle: ButtonStyle {
    var diameter: CGFloat = 76
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.40, weight: .heavy))
            .foregroundColor(Theme.bone)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(Theme.redGradient))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
            .shadow(color: Theme.red.opacity(0.55),
                    radius: configuration.isPressed ? 8 : 20, y: 5)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Full-width capsule action button (red or rose gradient). Useful for
/// primary actions on sheets and detail screens.
struct PillButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Theme.redGradient
    var textColor: Color = Theme.bone
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(16, weight: .bold))
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().fill(gradient))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
