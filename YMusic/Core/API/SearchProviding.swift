import Foundation

/// Поиск по каталогу. Отдельный протокол, чтобы `SearchViewModel` не знал
/// про конкретный путь и в превью можно было подставить статичный ответ.
protocol SearchProviding: Sendable {
    /// `page` считается с нуля, как у Яндекс.API. `limit` — пожелание UI;
    /// сервер отдаёт свой размер страницы, поэтому на него не полагаемся.
    /// `type` — быстрый фильтр (`all`, `track`, `artist`, `album`, `playlist`).
    func search(query: String, type: String, page: Int, limit: Int) async throws -> SearchResult
}
