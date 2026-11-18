import CoreImage
import Foundation
import ImageIO
import OSLog
import SwiftUI

// MARK: - Цвет

/// Компоненты в sRGB, 0...1. Храним числа, а не `Color`: структура должна
/// быть `Sendable`, чтобы спокойно пересекать границу actor'а.
struct RGBColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    /// Относительная яркость по WCAG (линеаризованный sRGB).
    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, max(green, blue))
        let minValue = min(red, min(green, blue))
        let delta = maxValue - minValue

        var hue = 0.0
        if delta > 0.0001 {
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red.clamped(to: 0...1)
        self.green = green.clamped(to: 0...1)
        self.blue = blue.clamped(to: 0...1)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let h = hue - floor(hue)
        let s = saturation.clamped(to: 0...1)
        let v = brightness.clamped(to: 0...1)

        let sector = Int(h * 6) % 6
        let fraction = h * 6 - Double(Int(h * 6))

        let p = v * (1 - s)
        let q = v * (1 - fraction * s)
        let t = v * (1 - (1 - fraction) * s)

        switch sector {
        case 0: red = v; green = t; blue = p
        case 1: red = q; green = v; blue = p
        case 2: red = p; green = v; blue = t
        case 3: red = p; green = q; blue = v
        case 4: red = t; green = p; blue = v
        default: red = v; green = p; blue = q
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Палитра

struct ColorPalette: Equatable, Sendable {
    let primary: RGBColor
    let secondary: RGBColor

    /// Фолбэк: фирменные цвета, если обложки нет или извлечение не удалось.
    static let brand = ColorPalette(
        primary: RGBColor(red: 0.55, green: 0.10, blue: 0.20),
        secondary: RGBColor(red: 0.18, green: 0.12, blue: 0.40)
    )

    var contentTone: ContentTone {
        primary.relativeLuminance > 0.60 ? .dark : .light
    }
}

// MARK: - Извлечение

/// Достаёт доминирующий цвет обложки через CoreImage.
///
/// Один `CIContext` на всё приложение: создание контекста — дорогая операция,
/// а его внутренние кэши не потокобезопасны для параллельного рендера.
/// Поэтому изоляция actor'ом, а не глобальный singleton-контекст.
actor ColorExtractor {
    static let shared = ColorExtractor()

    private let logger = Logger(subsystem: "com.example.ymusic", category: "ColorExtractor")
    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private var cache: [String: ColorPalette] = [:]
    /// Порядок вставки для LRU-подобного вытеснения: при переполнении
    /// убираем самую старую запись, а не сбрасываем весь кэш (иначе на
    /// 201-й обложке палитры пересчитывались заново для всего экрана).
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<ColorPalette?, Never>] = [:]
    private let cacheLimit = 200

    init() {
        context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
    }

    /// Палитра по URL. Результат кэшируется по `key`; одинаковые
    /// параллельные запросы делят одну задачу загрузки.
    func palette(forKey key: String, from url: URL) async -> ColorPalette? {
        if let cached = cache[key] {
            return cached
        }
        if let running = inFlight[key] {
            return await running.value
        }

        let task = Task<ColorPalette?, Never> { await self.extract(from: url) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)

        if let result {
            store(result, forKey: key)
        }
        return result
    }

    /// Основной путь после Фазы 3: байты уже скачаны `ImageLoader`, повторный
    /// запрос не нужен. `Data` — Sendable, в отличие от `CGImage`.
    func palette(forKey key: String, fromData data: Data) -> ColorPalette? {
        if let cached = cache[key] {
            return cached
        }

        guard
            let image = Self.downsampledImage(from: data),
            let result = Self.makePalette(from: image, context: context, colorSpace: colorSpace)
        else {
            return nil
        }

        store(result, forKey: key)
        return result
    }

    /// Палитра из уже загруженного изображения (аватар, локальный ассет).
    func palette(forKey key: String, from image: CGImage) -> ColorPalette? {
        if let cached = cache[key] {
            return cached
        }

        guard let result = Self.makePalette(from: image, context: context, colorSpace: colorSpace) else {
            return nil
        }

        store(result, forKey: key)
        return result
    }

    func clearCache() {
        cache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
    }

    // MARK: - Внутреннее

    private func store(_ palette: ColorPalette, forKey key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = palette

        while cacheOrder.count > cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func extract(from url: URL) async -> ColorPalette? {
        do {
            let data: Data

            if url.isFileURL {
                // Локальный ассет: URLSession с file:// не работает.
                data = try Data(contentsOf: url)
            } else {
                let (payload, response) = try await URLSession.shared.data(from: url)

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    logger.debug("Обложка пропущена: HTTP \(http.statusCode)")
                    return nil
                }
                data = payload
            }

            guard let image = Self.downsampledImage(from: data) else {
                logger.debug("Не удалось декодировать обложку")
                return nil
            }

            return Self.makePalette(from: image, context: context, colorSpace: colorSpace)
        } catch {
            logger.debug("Загрузка обложки не удалась: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Уменьшаем картинку до 64 px до рендера: CIAreaAverage на полноразмерной
    /// обложке тратит память и время без выигрыша в точности.
    private static func downsampledImage(from data: Data, maxPixel: Int = 64) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makePalette(
        from image: CGImage,
        context: CIContext,
        colorSpace: CGColorSpace?
    ) -> ColorPalette? {
        // Мелкие картинки (иконки, битые превью) не дают осмысленного среднего.
        guard image.width >= 8, image.height >= 8 else { return nil }

        let ciImage = CIImage(cgImage: image)
        guard let average = averageColor(of: ciImage, context: context, colorSpace: colorSpace) else {
            return nil
        }

        let primary = deepTone(average)
        let secondary = rotated(primary, hueShift: 0.07, brightnessScale: 0.85)
        return ColorPalette(primary: primary, secondary: secondary)
    }

    private static func averageColor(
        of image: CIImage,
        context: CIContext,
        colorSpace: CGColorSpace?
    ) -> RGBColor? {
        guard
            let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: image.extent)
            ]),
            let output = filter.outputImage
        else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: pixel.count,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        )

        return RGBColor(
            red: Double(pixel[0]) / 255,
            green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255
        )
    }

    /// Средний цвет обложки почти всегда серо-коричневый. Поднимаем насыщенность
    /// и прижимаем яркость, чтобы фон работал под белый текст.
    private static func deepTone(_ color: RGBColor) -> RGBColor {
        let hsb = color.hsb
        let saturation = min(1.0, max(0.42, hsb.saturation * 1.3))
        let brightness = min(0.42, max(0.20, hsb.brightness * 0.85 + 0.06))
        return RGBColor(hue: hsb.hue, saturation: saturation, brightness: brightness)
    }

    private static func rotated(
        _ color: RGBColor,
        hueShift: Double,
        brightnessScale: Double
    ) -> RGBColor {
        let hsb = color.hsb
        return RGBColor(
            hue: hsb.hue + hueShift,
            saturation: min(1, hsb.saturation * 1.05),
            brightness: max(0.16, hsb.brightness * brightnessScale)
        )
    }
}
