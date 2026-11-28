// Exercise the same typed, owned temporary handed to the production bridge.
import Foundation

private struct Track {
    let id: String
    var title: String
    var singer: String?
    var artist: String?
    var cover: String?
}

private final class Library {
    var downloaded: [Track] = []
    var favorites: [Track] = []
}

@main struct DownloadSortTests {
    static func main() throws {
        let library = Library()
        func row(_ id: String, _ title: String, _ singer: String? = nil, _ artist: String? = nil) -> Track {
            Track(id: id, title: title, singer: singer, artist: artist, cover: nil)
        }
        func view() -> [Track] {
            var visible = library.downloaded
            withUnsafeMutablePointer(to: &visible) { ptr in
                FMProjectDownloadRead(UnsafeMutableRawPointer(ptr), path: \Library.downloaded,
                                      ownerType: String(reflecting: Library.self), rowType: String(reflecting: Track.self))
            }
            return visible
        }
        var evidence: [String: Bool] = [:]
        func check(_ field: String, _ result: Bool) {
            precondition(result, field)
            evidence[field] = true
        }
        let source = [
            row("other", "かな"), row("n10", "Animal 10"), row("z", "知我"), row("second", "Echo", nil, "Mina"),
            row("n2", "Animal 2"), row("b", "北京"), row("e7", "7 Years"), row("remix", "Echo (Remix)"),
            row("sym", "🎵"), row("cnnum", "３只鸟"), row("a", "♪安静"), row("live", "Echo (Live)"),
            row("zhmix", "安静 Home"), row("first", "Écho", "Anna"), row("third", "echo", "Mina"),
            row("emix", "Zebra 中文"), row("two", "2")
        ]
        library.downloaded = source
        library.favorites = Array(source.reversed())
        let ids = view().map(\.id)
        let groups = Array(ids.prefix(5))
        check("groups", Set(groups) == Set(["cnnum", "a", "zhmix", "b", "z"]) &&
              Set(ids.suffix(3)) == Set(["other", "sym", "two"]))
        check("pinyin", groups == ["cnnum", "a", "zhmix", "b", "z"])
        let english = Array(ids.dropFirst(5).dropLast(3))
        check("numeric", Array(english.prefix(3)) == ["e7", "n2", "n10"] && english.last == "emix")
        check("versions", english.filter { $0 == "live" || $0 == "remix" } == ["live", "remix"])
        check("stable_ties", english.filter { ["first","second","third"].contains($0) } == ["first","second","third"])
        check("initial", view().map(\.id) == ids)
        check("source_unchanged", library.downloaded.map(\.id) == source.map(\.id))
        check("other_playlists", library.favorites.map(\.id) == Array(source.map(\.id).reversed()))
        library.downloaded.append(row("new", "大海"))
        let after = view().map(\.id)
        check("completion", Array(after.prefix(6)) == ["cnnum","a","zhmix","b","new","z"])
        let selected = view()[4]
        let queue = view()
        check("selection_queue", selected.id == "new" && queue.map(\.id) == after && queue[5].id == "z")
        library.downloaded.removeAll { $0.id == selected.id }
        check("delete", view().map(\.id) == ids)
        let coverIndex = library.downloaded.firstIndex { $0.id == "n2" }!
        library.downloaded[coverIndex].cover = "file:///fixture-cover.jpg"
        check("cover_refresh", view().map(\.id) == ids && view().first { $0.id == "n2" }?.cover == "file:///fixture-cover.jpg")
        var foreign = source
        withUnsafeMutablePointer(to: &foreign) { ptr in
            FMProjectDownloadRead(UnsafeMutableRawPointer(ptr), path: \Library.downloaded,
                                  ownerType: "Invalid.Owner", rowType: String(reflecting: Track.self))
        }
        check("foreign_owner", foreign.map(\.id) == source.map(\.id))
        library.downloaded = []
        check("empty", view().isEmpty)
        library.downloaded = [row("one","One")]
        check("one", view().map(\.id) == ["one"])
        var report: [String: Any] = evidence
        report["passed"] = true
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("DONE download sort tests")
    }
}
