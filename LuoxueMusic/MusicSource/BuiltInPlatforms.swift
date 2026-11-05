import Foundation

/// 自带平台音源（对应洛雪「软件自带音乐库」）：
///
/// 洛雪音乐官方实现中，搜索与曲库浏览由应用**内置的平台音源**（酷狗/网易云/QQ/酷我/咪咕）完成，
/// 用户导入的自定义音源只负责「放出来」（musicUrl / lyric / pic）。
/// 本模块即应用的自带平台音源：内置网易云、酷我两个平台的搜索、播放直链与歌词，
/// 保证不导入任何音源也能搜到真实歌曲；导入音源后播放取链优先走音源。
enum BuiltInPlatforms {

    /// 平台标识与展示名
    static let all: [(id: String, name: String)] = [("wy", "网易云"), ("kw", "酷我"), ("tx", "QQ音乐")]

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
        case "tx":
            // QQ 音乐公开搜索接口（周杰伦等版权歌曲在网易云/酷我缺失，QQ 曲库可搜到）。
            guard let data = await get(
                "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=\(keyword.urlEncoded)&format=json&n=\(limit)&p=\(page)&cr=1&g_tk=5381&t=0&platform=yqq.json",
                headers: ["Referer": "https://y.qq.com/",
                          "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"]
            ) else { return [] }
            return parseQQSongs(data)
        default:
            return []
        }
    }

    /// QQ 音乐搜索结果解析：data.song.list[] → Song（封面用 albummid 拼图床地址）。
    static func parseQQSongs(_ data: Data) -> [Song] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let song = payload["song"] as? [String: Any],
              let list = song["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let mid = item["songmid"] as? String
                    ?? (item["songid"] as? Int).map(String.init)
                    ?? (item["songid"] as? String) else { return nil }
            let singers = (item["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let albumMid = item["albummid"] as? String ?? ""
            let pic = albumMid.isEmpty ? ""
                : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg"
            let interval = (item["interval"] as? Int) ?? ((item["interval"] as? Double).map { Int($0) }) ?? 0
            return Song(source: "tx", songId: mid,
                        title: item["songname"] as? String ?? "",
                        artist: singers.joined(separator: " / "),
                        album: item["albumname"] as? String ?? "",
                        duration: interval,
                        picUrl: pic, lrcUrl: "")
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
            // 免费外链最稳：无需 Cookie，服务端 302 跳转到音频 CDN 直链（实测可下到完整音频）。
            // 官方 enhance/player/url 接口现已对无 Cookie 请求返回验证拦截（code -462），仅作兜底。
            let outer = "https://music.163.com/song/media/outer/url?id=\(song.songId).mp3"
            if await probeAudio(outer, headers: ["Referer": "https://music.163.com"]) {
                return outer
            }
            if let data = await postForm(
                "https://music.163.com/api/song/enhance/player/url",
                form: ["ids": "[\(song.songId)]", "br": "320000"],
                headers: ["Referer": "https://music.163.com"]
            ), let url = parseNeteaseUrl(data) { return url }
            // 探测失败也直接返回外链（部分 CDN 不支持 Range 探测，但实际可播）。
            return outer
        case "kw":
            guard let data = await get(
                "http://www.kuwo.cn/api/v1/www/music/playUrl?mid=\(song.songId)&type=music&httpsStatus=1",
                headers: ["Referer": "http://www.kuwo.cn/", "csrf": "lx\(Int.random(in: 100_000...999_999))",
                          "Cookie": "kw_token=lx\(Int.random(in: 100_000...999_999))"]
            ), let url = parseKuwoUrl(data) else { return nil }
            return url
        case "tx":
            // QQ 音乐 vkey 接口：非 VIP/非版权受限歌曲可直接取到直链（sip 前缀 + purl）。
            guard let data = await get(
                "https://u.y.qq.com/cgi-bin/musicu.fcg?format=json&data=\(qqVkeyPayload(song.songId).urlEncoded)",
                headers: ["Referer": "https://y.qq.com/",
                          "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"]
            ), let url = parseQQUrl(data) else { return nil }
            return url
        default:
            return nil
        }
    }

    /// QQ 音乐 vkey.GetVkey 请求载荷（免登录，guid 用固定值）。
    static func qqVkeyPayload(_ songId: String) -> String {
        let payload: [String: Any] = [
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "guid": "10000",
                    "songmid": [songId],
                    "songtype": [0],
                    "uin": "0",
                    "loginflag": 1,
                    "platform": "20"
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// QQ 音乐 vkey 响应解析：data.req_1.data.{sip, midurlinfo[0].purl}。
    static func parseQQUrl(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reqData = root["data"] as? [String: Any],
              let req1 = reqData["req_1"] as? [String: Any],
              let inner = req1["data"] as? [String: Any],
              let infos = inner["midurlinfo"] as? [[String: Any]],
              let purl = infos.first?["purl"] as? String, !purl.isEmpty else { return nil }
        // sip 是 CDN 前缀（可能多个，取第一个非空），purl 是文件路径。
        let prefix = (inner["sip"] as? [String])?.first(where: { !$0.isEmpty }) ?? ""
        return prefix.hasSuffix("/") || purl.hasPrefix("http") ? prefix + purl : prefix + "/" + purl
    }

    /// 探测一个 URL 是否真正返回音频（外链接口对不可播的歌回 404/HTML）。
    static func probeAudio(_ url: String, headers: [String: String]) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return false }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return type.contains("audio") || type.contains("octet") || data.count > 512
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
        switch platform {
        case "wy":
            guard let data = await get("https://music.163.com/api/song/lyric?id=\(song.songId)&lv=1&kv=1&tv=-1",
                                       headers: ["Referer": "https://music.163.com"]),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrc = root["lrc"] as? [String: Any],
                  let text = lrc["lyric"] as? String, !text.isEmpty else { return nil }
            return text
        case "tx":
            // QQ 音乐歌词（base64 编码），导入音源无歌词时兜底。
            guard let data = await get(
                "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(song.songId)&format=json&g_tk=5381&platform=yqq.json",
                headers: ["Referer": "https://y.qq.com/"]
            ), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let b64 = root["lyric"] as? String, !b64.isEmpty,
               let decoded = Data(base64Encoded: b64),
               let text = String(data: decoded, encoding: .utf8), !text.isEmpty else { return nil }
            return text
        default:
            return nil
        }
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
