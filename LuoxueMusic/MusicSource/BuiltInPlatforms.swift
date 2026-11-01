import Foundation

/// 自带平台音源（对应洛雪「软件自带音乐库」）：
///
/// 洛雪音乐官方实现中，搜索与曲库浏览由应用**内置的平台音源**（酷狗/网易云/QQ/酷我/咪咕）完成，
/// 用户导入的自定义音源只负责「放出来」（musicUrl / lyric / pic）。
/// 本模块即应用的自带平台音源：内置网易云、酷我两个平台的搜索、播放直链与歌词，
/// 保证不导入任何音源也能搜到真实歌曲；导入音源后播放取链优先走音源。
enum BuiltInPlatforms {

    /// 平台标识与展示名
    static let all: [(id: String, name: String)] = [("wy", "网易云"), ("kw", "酷我")]

    // MARK: - 搜索

    /// 内置平台搜索（洛雪官方形态：返回统一 Song 列表）。
    static func search(platform: String, keyword: String, page: Int = 1, limit: Int = 30) async -> [Song] {
        switch platform {
        case "wy":
            guard let data = await postForm(
                "https://music.163.com/api/search/get/web",
                form: ["s": keyword, "type": "1", "limit": String(limit), "offset": String((page - 1) * limit)],
                headers: ["Referer": "https://music.163.com"]
            ) else { return [] }
            return parseNeteaseSongs(data)
        case "kw":
            // 酷我 www API 要求 csrf 参数与 kw_token Cookie 一致，可用随机 token 自配。
            let token = "lx\(Int.random(in: 100_000...999_999))"
            guard let data = await get(
                "http://www.kuwo.cn/api/www/search/searchMusicBykeyWord?key=\(keyword.urlEncoded)&pn=\(page)&rn=\(limit)&httpsStatus=1",
                headers: ["csrf": token, "Cookie": "kw_token=\(token)", "Referer": "http://www.kuwo.cn/",
                          "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"]
            ) else { return [] }
            return parseKuwoSongs(data)
        default:
            return []
        }
    }

    /// 网易云搜索结果解析：result.songs[] → Song
    static func parseNeteaseSongs(_ data: Data) -> [Song] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return [] }
        return songs.compactMap { item in
            guard let id = (item["id"] as? Int).map(String.init) ?? (item["id"] as? String) else { return nil }
            let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let durationMs = (item["duration"] as? Int) ?? ((item["duration"] as? Double).map { Int($0) }) ?? 0
            let pic = (item["album"] as? [String: Any])?["picUrl"] as? String ?? ""
            return Song(source: "wy", songId: id,
                        title: item["name"] as? String ?? "",
                        artist: artists.joined(separator: " / "),
                        album: (item["album"] as? [String: Any])?["name"] as? String ?? "",
                        duration: durationMs / 1000,
                        picUrl: pic, lrcUrl: "")
        }
    }

    /// 酷我搜索结果解析：data.list[] → Song
    static func parseKuwoSongs(_ data: Data) -> [Song] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let list = payload["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = (item["rid"] as? Int).map(String.init)
                    ?? (item["rid"] as? String)
                    ?? (item["mid"] as? Int).map(String.init)
                    ?? (item["mid"] as? String) else { return nil }
            let durationSec = (item["duration"] as? Int) ?? ((item["duration"] as? Double).map { Int($0) }) ?? 0
            return Song(source: "kw", songId: id,
                        title: item["name"] as? String ?? item["songName"] as? String ?? "",
                        artist: item["artist"] as? String ?? "",
                        album: item["album"] as? String ?? item["albumName"] as? String ?? "",
                        duration: durationSec,
                        picUrl: item["pic"] as? String ?? item["img"] as? String ?? "",
                        lrcUrl: "")
        }
    }

    // MARK: - 播放直链最后兜底
    //
    // 用户要求：非 VIP 的内置平台歌曲应始终可放（导入音源失败时兜底）。
    // 网易云/酷我的公开直链接口对大部分免费歌曲可用，VIP/版权歌曲拿不到——这类歌必须靠导入音源。

    static func playUrl(platform: String, song: Song) async -> String? {
        switch platform {
        case "wy":
            guard let data = await postForm(
                "https://music.163.com/api/song/enhance/player/url",
                form: ["ids": "[\(song.songId)]", "br": "320000"],
                headers: ["Referer": "https://music.163.com"]
            ), let url = parseNeteaseUrl(data) else { return nil }
            return url
        case "kw":
            guard let data = await get(
                "http://www.kuwo.cn/api/v1/www/music/playUrl?mid=\(song.songId)&type=music&httpsStatus=1",
                headers: ["Referer": "http://www.kuwo.cn/", "csrf": "lx\(Int.random(in: 100_000...999_999))",
                          "Cookie": "kw_token=lx\(Int.random(in: 100_000...999_999))"]
            ), let url = parseKuwoUrl(data) else { return nil }
            return url
        default:
            return nil
        }
    }

    static func parseNeteaseUrl(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [[String: Any]],
              let url = payload.first?["url"] as? String, !url.isEmpty else { return nil }
        return url
    }

    static func parseKuwoUrl(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let url = payload["url"] as? String, !url.isEmpty else { return nil }
        return url
    }

    // MARK: - 歌词兜底
    //
    // 播放直链优先用导入的音源，内置平台直链仅作最后兜底；
    // 歌词属于展示信息，保留网易云歌词接口作为兜底。

    static func lyric(platform: String, song: Song) async -> String? {
        guard platform == "wy",
              let data = await get("https://music.163.com/api/song/lyric?id=\(song.songId)&lv=1&kv=1&tv=-1",
                                   headers: ["Referer": "https://music.163.com"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lrc = root["lrc"] as? [String: Any],
              let text = lrc["lyric"] as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - HTTP

    private static func postForm(_ url: String, form: [String: String], headers: [String: String]) async -> Data? {
        guard var comps = URLComponents(string: url) else { return nil }
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = comps.url else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data()
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return try? await URLSession.shared.data(for: req).0
    }

    private static func get(_ url: String, headers: [String: String]) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return try? await URLSession.shared.data(for: req).0
    }
}

extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
