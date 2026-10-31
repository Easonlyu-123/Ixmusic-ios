import Foundation

/// 一首歌曲（搜索结果 / 播放列表中的条目）。
/// 字段宽松映射洛雪音源返回的常见结构。
struct Song: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// 来自哪个音源的 platform 标识
    var source: String
    /// 音源内的歌曲唯一 id（洛雪常用 songmid / id）
    var songId: String
    var title: String
    var artist: String
    var album: String
    var duration: Int
    var picUrl: String
    var lrcUrl: String

    var displayTitle: String { title.isEmpty ? "(未知曲目)" : title }
    var displayArtist: String { artist.isEmpty ? "未知歌手" : artist }
}

/// 一个自定义音源：完整保留洛雪的 JS 源脚本，格式不变。
struct MusicSource: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var version: String
    var platform: String
    var author: String
    /// 洛雪格式的音源脚本全文（module.exports = {...}）
    var script: String
    var enabled: Bool

    init(id: UUID = UUID(), name: String, version: String, platform: String,
         author: String, script: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.version = version
        self.platform = platform
        self.author = author
        self.script = script
        self.enabled = enabled
    }
}
