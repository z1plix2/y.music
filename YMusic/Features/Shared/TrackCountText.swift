import Foundation

/// Русские формы числительных для счётчиков: «1 трек», «2 трека», «11 треков».
///
/// Нужно, чтобы шапка альбома и статистика артиста не писали «1 треков».
enum TrackCountText {
    static func tracks(_ count: Int) -> String {
        "\(count) \(word(count, one: "трек", few: "трека", many: "треков"))"
    }

    static func albums(_ count: Int) -> String {
        "\(count) \(word(count, one: "альбом", few: "альбома", many: "альбомов"))"
    }

    private static func word(_ count: Int, one: String, few: String, many: String) -> String {
        let value = Swift.abs(count)
        let mod100 = value % 100
        let mod10 = value % 10

        if mod100 >= 11 && mod100 <= 14 {
            return many
        }

        switch mod10 {
        case 1:
            return one
        case 2...4:
            return few
        default:
            return many
        }
    }
}