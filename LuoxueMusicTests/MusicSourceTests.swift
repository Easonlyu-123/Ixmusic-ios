import Foundation
import Testing
@testable import LuoxueMusic

@Suite("洛雪音源运行时")
struct MusicSourceRuntimeTests {

    @Test("演示音源搜索返回结果，且保留洛雪字段")
    func demoSearch() async {
        let runtime = SourceRuntime()
        let source = BuiltInDemoSource.makeMusicSource()
        let songs = await runtime.search(source: source, query: "周杰伦")
        #expect(songs != nil)
        #expect(songs?.count == 2)
        #expect(songs?.first?.title.contains("周杰伦") == true)
        #expect(songs?.first?.source == "demo")
        #expect(songs?.first?.album == "演示专辑")
    }

    @Test("演示音源返回可播放音频 URL")
    func demoUrl() async {
        let runtime = SourceRuntime()
        let source = BuiltInDemoSource.makeMusicSource()
        let song = Song(source: "demo", songId: "demo-1", title: "x", artist: "y",
                        album: "z", duration: 0, picUrl: "", lrcUrl: "")
        let url = await runtime.getUrl(source: source, song: song)
        #expect(url != nil)
        #expect(url?.contains("SoundHelix") == true)
    }

    @Test("演示音源返回歌词")
    func demoLyric() async {
        let runtime = SourceRuntime()
        let source = BuiltInDemoSource.makeMusicSource()
        let song = Song(source: "demo", songId: "demo-1", title: "x", artist: "y",
                        album: "z", duration: 0, picUrl: "", lrcUrl: "")
        let lyric = await runtime.getLyric(source: source, song: song)
        #expect(lyric != nil)
        #expect(lyric?.contains("演示音源") == true)
    }

    @Test("音源模型可编码往返，脚本格式保持不变")
    func sourceCodable() throws {
        let source = BuiltInDemoSource.makeMusicSource()
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(MusicSource.self, from: data)
        #expect(decoded.platform == "demo")
        #expect(decoded.script.contains("globalThis.lx"))
        #expect(decoded.script == source.script)
    }

    @Test("自定义音源脚本（洛雪格式）能被解析并搜索")
    func customSourceSearch() async {
        let script = """
        const source = {
          name: '自定义测试源',
          version: '2.0.0',
          platform: 'mytest',
          author: 'tester',
          async musicSearch(query, page, limit) {
            return [ { songmid: 'a1', songname: query + ' 测试', singer: '张三', albumname: '测试辑' } ];
          }
        };
        module.exports = source;
        """
        let source = MusicSource(name: "自定义测试源", version: "2.0.0", platform: "mytest",
                                author: "tester", script: script, enabled: true)
        let runtime = SourceRuntime()
        let songs = await runtime.search(source: source, query: "hello")
        #expect(songs != nil)
        #expect(songs?.count == 1)
        #expect(songs?.first?.title == "hello 测试")
    }

    // MARK: - 洛雪官方 user-api 格式（globalThis.lx）

    private func makeLxApiSource() -> MusicSource {
        let script = """
        /**
         * @name LX官方格式测试源
         * @description 测试 globalThis.lx user-api
         * @version 3.1.0
         * @author lxtester
         * @homepage https://example.com
         */
        const { EVENT_NAMES, on, send, utils } = globalThis.lx;

        on(EVENT_NAMES.request, ({ source, action, info }) => {
          if (action === 'music/search' || action === 'musicSearch') {
            return {
              list: [ { songmid: 'lx-1', songname: info.searchWord + ' LX', singer: [{ name: '李四' }], albumName: 'LX专辑', interval: 180, source: source } ],
              total: 1, allPage: 1, limit: info.limit
            };
          }
          if (action === 'music/url' || action === 'musicUrl') {
            return 'https://example.com/' + info.musicInfo.songmid + '.mp3';
          }
          if (action === 'lyric') {
            return { lyric: '[00:01.00]LX官方格式歌词' };
          }
        });

        send(EVENT_NAMES.inited, { status: true, openDevTools: false, sources: { musicSearch: true, musicUrl: true, lyric: true } });
        """
        return MusicSource(name: "LX官方格式测试源", version: "3.1.0", platform: "lxtest",
                           author: "lxtester", script: script, enabled: true)
    }

    @Test("洛雪官方 user-api 格式：搜索返回结果并解析 lx 字段")
    func lxApiSearch() async {
        let runtime = SourceRuntime()
        let source = makeLxApiSource()
        let songs = await runtime.search(source: source, query: "周杰伦")
        #expect(songs != nil)
        #expect(songs?.count == 1)
        #expect(songs?.first?.title == "周杰伦 LX")
        #expect(songs?.first?.artist == "李四")           // singer 数组会被拍平
        #expect(songs?.first?.album == "LX专辑")          // albumName 字段
        #expect(songs?.first?.duration == 180)
    }

    @Test("洛雪官方 user-api 格式：musicUrl 与 lyric 动作")
    func lxApiUrlAndLyric() async {
        let runtime = SourceRuntime()
        let source = makeLxApiSource()
        let song = Song(source: "lxtest", songId: "lx-1", title: "x", artist: "y",
                        album: "z", duration: 0, picUrl: "", lrcUrl: "")
        let url = await runtime.getUrl(source: source, song: song)
        #expect(url == "https://example.com/lx-1.mp3")
        let lyric = await runtime.getLyric(source: source, song: song)
        #expect(lyric?.contains("LX官方格式歌词") == true)
    }

    @Test("lx.utils：md5 与 buffer base64 可用")
    func lxUtilsCryptoAndBuffer() async {
        let script = """
        const { EVENT_NAMES, on, send, utils } = globalThis.lx;
        on(EVENT_NAMES.request, ({ action }) => {
          if (action === 'music/search' || action === 'musicSearch') {
            return { list: [
              { songmid: 'm1', songname: utils.crypto.md5('abc'), singer: 'h' },
              { songmid: 'm2', songname: utils.buffer.from('你好', 'utf-8').toString('base64'), singer: 'h' }
            ] };
          }
        });
        send(EVENT_NAMES.inited, { status: true, sources: { musicSearch: true } });
        """
        let source = MusicSource(name: "utils测试", version: "1.0.0", platform: "ux",
                                 author: "t", script: script, enabled: true)
        let runtime = SourceRuntime()
        let songs = await runtime.search(source: source, query: "x")
        #expect(songs?.count == 2)
        #expect(songs?[0].title == "900150983cd24fb0d6963f7d28e17f72")
        #expect(songs?[1].title == "5L2g5aW9")
    }

    @Test("脚本头信息解析：@name/@author/@version")
    func parseScriptHeader() {
        let info = SourceRuntime.parseScriptInfo(makeLxApiSource().script)
        #expect(info["name"] as? String == "LX官方格式测试源")
        #expect(info["author"] as? String == "lxtester")
        #expect(info["version"] as? String == "3.1.0")
    }

    @Test("同一官方格式音源可反复搜索（缓存与作用域隔离）")
    func lxApiRepeatedSearch() async {
        let runtime = SourceRuntime()
        let source = makeLxApiSource()
        let first = await runtime.search(source: source, query: "a")
        let second = await runtime.search(source: source, query: "b")
        #expect(first?.first?.title == "a LX")
        #expect(second?.first?.title == "b LX")
    }

    // MARK: - 自带平台音源解析（洛雪官方模式：搜索由应用内置平台完成）

    @Test("内置网易云搜索结果解析")
    func neteaseSearchParsing() throws {
        let json = """
        {"code":200,"result":{"songs":[
          {"id":186016,"name":"晴天","artists":[{"id":1,"name":"周杰伦"}],
           "album":{"name":"叶惠美","picUrl":"https://p.example/a.jpg"},"duration":269306},
          {"id":2,"name":"稻香","artists":[{"name":"周杰伦"},{"name":"其他"}],"album":{"name":"魔杰座"},"duration":223000}
        ]}}
        """.data(using: .utf8)!
        let songs = BuiltInPlatforms.parseNeteaseSongs(json)
        #expect(songs.count == 2)
        #expect(songs[0].source == "wy")
        #expect(songs[0].songId == "186016")
        #expect(songs[0].title == "晴天")
        #expect(songs[0].artist == "周杰伦")
        #expect(songs[0].album == "叶惠美")
        #expect(songs[0].duration == 269)
        #expect(songs[0].picUrl == "https://p.example/a.jpg")
        #expect(songs[1].artist == "周杰伦 / 其他")
    }

    @Test("内置酷我搜索结果解析")
    func kuwoSearchParsing() throws {
        let json = """
        {"code":200,"success":true,"data":{"total":2,"list":[
          {"rid":228908,"name":"孤勇者","artist":"陈奕迅","album":"孤勇者","duration":264,"pic":"https://kw.example/b.jpg"},
          {"mid":"kwx2","songName":"十年","artist":"陈奕迅","albumName":"黑·白·灰","duration":315}
        ]}}
        """.data(using: .utf8)!
        let songs = BuiltInPlatforms.parseKuwoSongs(json)
        #expect(songs.count == 2)
        #expect(songs[0].source == "kw")
        #expect(songs[0].songId == "228908")
        #expect(songs[0].title == "孤勇者")
        #expect(songs[0].duration == 264)
        #expect(songs[1].songId == "kwx2")
        #expect(songs[1].title == "十年")
        #expect(songs[1].album == "黑·白·灰")
    }

    @Test("内置平台解析对空/畸形数据安全")
    func builtinParsingSafeOnBadData() {
        #expect(BuiltInPlatforms.parseNeteaseSongs(Data("not json".utf8)).isEmpty)
        #expect(BuiltInPlatforms.parseKuwoSongs(Data("{}".utf8)).isEmpty)
    }

    @Test("取链失败时透传脚本报错原因")
    func getUrlReportsScriptError() async {
        let script = """
        const { EVENT_NAMES, on, send } = globalThis.lx;
        on(EVENT_NAMES.request, ({ source, action, info }) => {
          if (action === 'musicUrl') return Promise.reject(new Error('vip locked'));
          return Promise.resolve('');
        });
        send(EVENT_NAMES.inited, { sources: { wy: { name: 'err', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } } });
        """
        let source = MusicSource(name: "报错音源", version: "1.0.0", platform: "custom",
                                 author: "t", script: script, enabled: true)
        let runtime = SourceRuntime()
        let song = Song(source: "wy", songId: "1", title: "t", artist: "a",
                        album: "al", duration: 1, picUrl: "", lrcUrl: "")
        let (url, error) = await runtime.getUrlWithReport(source: source, song: song)
        #expect(url == nil)
        #expect(error?.contains("vip locked") == true)
    }

    @Test("按 inited 声明的 musicUrl 动作取链成功")
    func getUrlUsesDeclaredAction() async {
        let script = """
        const { EVENT_NAMES, on, send } = globalThis.lx;
        on(EVENT_NAMES.request, ({ source, action, info }) => {
          if (action === 'musicUrl') return Promise.resolve('https://example.com/' + info.musicInfo.songmid + '.mp3');
          return Promise.reject(new Error('unsupported action ' + action));
        });
        send(EVENT_NAMES.inited, { sources: { wy: { name: 'x', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } } });
        """
        let source = MusicSource(name: "声明动作音源", version: "1.0.0", platform: "custom",
                                 author: "t", script: script, enabled: true)
        let runtime = SourceRuntime()
        let song = Song(source: "wy", songId: "42", title: "t", artist: "a",
                        album: "al", duration: 1, picUrl: "", lrcUrl: "")
        let (url, error) = await runtime.getUrlWithReport(source: source, song: song)
        #expect(url == "https://example.com/42.mp3")
        #expect(error == nil)
    }

    // MARK: - LRC 歌词解析（Apple Music 风格歌词页）

    @Test("LRC 解析：时间标签、多标签行、乱序排序")
    func lrcParsing() {
        let lrc = """
        [00:00.50]第一行
        [00:10][00:30.5]重复行
        [xx:yy]非法行
        [00:05.25]第二行
        纯文本行
        """
        let lines = LrcParser.parse(lrc)
        #expect(lines.map { $0.text } == ["第一行", "第二行", "重复行", "重复行"])
        #expect(abs(lines[0].time - 0.5) < 0.001)
        #expect(abs(lines[1].time - 5.25) < 0.001)
        #expect(abs(lines[2].time - 10.0) < 0.001)
        #expect(abs(lines[3].time - 30.5) < 0.001)
    }

    @Test("LRC 当前行二分定位")
    func lrcCurrentIndex() {
        let lines = LrcParser.parse("[00:01]A\n[00:05]B\n[00:09]C")
        #expect(LrcParser.currentIndex(of: lines, at: 0.5) == -1)
        #expect(LrcParser.currentIndex(of: lines, at: 1.0) == 0)
        #expect(LrcParser.currentIndex(of: lines, at: 6.0) == 1)
        #expect(LrcParser.currentIndex(of: lines, at: 99) == 2)
    }

    // MARK: - 内置平台直链解析（播放兜底）

    @Test("内置网易云直链解析")
    func neteaseUrlParsing() throws {
        let json = """
        {"data":[{"id":186016,"url":"http://m801.music.126.net/abc.mp3","br":320000}],"code":200}
        """.data(using: .utf8)!
        #expect(BuiltInPlatforms.parseNeteaseUrl(json) == "http://m801.music.126.net/abc.mp3")
        // VIP 无权限时 url 为 null
        let vip = """
        {"data":[{"id":2,"url":null,"code":-200}],"code":200}
        """.data(using: .utf8)!
        #expect(BuiltInPlatforms.parseNeteaseUrl(vip) == nil)
    }

    @Test("内置酷我直链解析")
    func kuwoUrlParsing() throws {
        let json = """
        {"code":200,"data":{"url":"http://other.web.ri01.sycdn.kuwo.cn/x.mp3"}}
        """.data(using: .utf8)!
        #expect(BuiltInPlatforms.parseKuwoUrl(json) == "http://other.web.ri01.sycdn.kuwo.cn/x.mp3")
        #expect(BuiltInPlatforms.parseKuwoSongs(Data("not json".utf8)).isEmpty)
    }

    @Test("内置 QQ 音乐搜索结果解析（封面由 albummid 拼接）")
    func qqSearchParsing() throws {
        let json = """
        {"code":0,"data":{"song":{"list":[{
            "songmid":"0039MnYb0qxYhV","songid":4830342,
            "songname":"晴天","albumname":"叶惠美","albummid":"002eFUFm2XYZ7z",
            "interval":269,
            "singer":[{"name":"周杰伦","mid":"0025NhlN2yWrP4"}]
        }]}}}
        """.data(using: .utf8)!
        let songs = BuiltInPlatforms.parseQQSongs(json)
        #expect(songs.count == 1)
        let s = try #require(songs.first)
        #expect(s.source == "tx")
        #expect(s.songId == "0039MnYb0qxYhV")
        #expect(s.title == "晴天")
        #expect(s.artist == "周杰伦")
        #expect(s.picUrl == "https://y.gtimg.cn/music/photo_new/T002R300x300M000002eFUFm2XYZ7z.jpg")
        #expect(s.duration == 269)
        // 畸形数据安全
        #expect(BuiltInPlatforms.parseQQSongs(Data("{}".utf8)).isEmpty)
    }

    /// 回归：导入音源（platform 常被填成 "custom"）必须按「歌曲所属平台」路由，
    /// 即请求里的 source 取 song.source，否则脚本内 apis[source] 取到 undefined 导致全部取链失败。
    @Test("取链按歌曲平台路由（修复导入音源 platform=custom 取链失败）")
    func getUrlRoutesBySongPlatform() async {
        let script = """
        const { EVENT_NAMES, on, send } = globalThis.lx;
        const apis = {
          wy: { musicUrl: (m) => 'https://wylink/' + m.songmid + '.mp3' },
          kw: { musicUrl: (m) => 'https://kwlinks/' + m.songmid + '.mp3' }
        };
        on(EVENT_NAMES.request, ({ source, action, info }) => {
          if (action !== 'musicUrl') return Promise.reject(new Error('unsupported ' + action));
          return Promise.resolve(apis[source].musicUrl(info.musicInfo));
        });
        send(EVENT_NAMES.inited, { sources: {
          wy: { name: '网易', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
          kw: { name: '酷我', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
        } });
        """
        // 模拟用户导入的音源：platform 填成 "custom"（旧逻辑的 bug 来源）。
        let source = MusicSource(name: "导入音源", version: "1.0.0", platform: "custom",
                                 author: "t", script: script, enabled: true)
        let runtime = SourceRuntime()
        let wySong = Song(source: "wy", songId: "112233", title: "t", artist: "a",
                          album: "al", duration: 1, picUrl: "", lrcUrl: "")
        let kwSong = Song(source: "kw", songId: "445566", title: "t", artist: "a",
                          album: "al", duration: 1, picUrl: "", lrcUrl: "")
        let (wyUrl, wyErr) = await runtime.getUrlWithReport(source: source, song: wySong)
        let (kwUrl, kwErr) = await runtime.getUrlWithReport(source: source, song: kwSong)
        #expect(wyUrl == "https://wylink/112233.mp3")
        #expect(wyErr == nil)
        #expect(kwUrl == "https://kwlinks/445566.mp3")
        #expect(kwErr == nil)
    }

    @Test("内置平台列表包含 QQ 音乐")
    func platformListContainsQQ() {
        #expect(BuiltInPlatforms.all.contains { $0.id == "tx" && $0.name == "QQ音乐" })
    }

    @Test("内置 QQ 音乐 vkey 直链解析与请求载荷")
    func qqVkeyParsing() throws {
        let payload = BuiltInPlatforms.qqVkeyPayload("0039MnYb0qxYhV")
        #expect(payload.contains("vkey.GetVkeyServer"))
        #expect(payload.contains("0039MnYb0qxYhV"))

        let json = """
        {"code":0,"data":{"req_1":{"code":0,"data":{
            "sip":["http://dl.stream.qqmusic.qq.com/","http://isure.stream.qqmusic.qq.com/"],
            "midurlinfo":[{"songmid":"0039MnYb0qxYhV","purl":"M5000039MnYb0qxYhV.mp3?guid=10000"}]
        }}}}
        """.data(using: .utf8)!
        #expect(BuiltInPlatforms.parseQQUrl(json)
                == "http://dl.stream.qqmusic.qq.com/M5000039MnYb0qxYhV.mp3?guid=10000")

        // VIP/受限歌曲 purl 为空 → 取不到直链
        let vip = """
        {"code":0,"data":{"req_1":{"code":0,"data":{
            "sip":["http://dl.stream.qqmusic.qq.com/"],
            "midurlinfo":[{"songmid":"xxx","purl":""}]
        }}}}
        """.data(using: .utf8)!
        #expect(BuiltInPlatforms.parseQQUrl(vip) == nil)
        #expect(BuiltInPlatforms.parseQQUrl(Data("not json".utf8)) == nil)
    }

    @Test("lx.request 请求体构造：Buffer shim / 字节数组 / 字符串 / JSON")
    func requestBodyBuilding() throws {
        // Buffer shim（JS Buffer 对象经 toDictionary 后的形态）必须还原为原始字节。
        var headers: [String: Any] = ["Content-Type": "application/json"]
        let bufferDict: [String: Any] = ["__lxbuf": 1, "length": 5,
                                         "data": [104, 101, 108, 108, 111]] // "hello"
        let data = try #require(SourceRuntime.requestBody(from: bufferDict, headers: &headers))
        #expect(Array(data) == [104, 101, 108, 108, 111])

        // 纯数字数组 → 原始字节。
        var h2: [String: Any] = [:]
        let arr: [Any] = [1, 2, 255]
        let arrData = try #require(SourceRuntime.requestBody(from: arr, headers: &h2))
        #expect(Array(arrData) == [1, 2, 255])

        // 字符串 → UTF-8。
        var h3: [String: Any] = [:]
        let strData = try #require(SourceRuntime.requestBody(from: "abc", headers: &h3))
        #expect(String(data: strData, encoding: .utf8) == "abc")

        // 字典 + JSON Content-Type → JSON 编码；否则表单编码。
        var jsonHeaders: [String: Any] = ["Content-Type": "application/json"]
        let dict: [String: Any] = ["a": 1, "b": "x"]
        let jsonData = try #require(SourceRuntime.requestBody(from: dict, headers: &jsonHeaders))
        let parsed = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        #expect(parsed["a"] as? Int == 1)
        var formHeaders: [String: Any] = [:]
        let formData = try #require(SourceRuntime.requestBody(from: dict, headers: &formHeaders))
        // 表单编码顺序不保证，按 key=value 对校验。
        let pairs = Set((String(data: formData, encoding: .utf8) ?? "").split(separator: "&"))
        #expect(pairs == ["a=1", "b=x"])

        // 空 body 安全。
        var h4: [String: Any] = [:]
        #expect(SourceRuntime.requestBody(from: nil, headers: &h4) == nil)
    }

}

@Suite("媒体库（最近播放 / 收藏）")
struct MediaLibraryTests {
    @Test("收藏切换：加→在列表头部；再切→移除")
    @MainActor
    func favoriteToggle() async {
        let store = AppStore()
        let song = Song(source: "wy", songId: "fav-1", title: "歌", artist: "人",
                        album: "专", duration: 10, picUrl: "", lrcUrl: "")
        let before = store.favorites.count
        store.toggleFavorite(song)
        #expect(store.isFavorite(song))
        #expect(store.favorites.first?.songId == "fav-1")
        store.toggleFavorite(song)
        #expect(!store.isFavorite(song))
        #expect(store.favorites.count == before)
    }

    @Test("重复播放同一首歌去重置顶，且自动进入最近播放")
    @MainActor
    func recentDedupAndTop() async {
        let store = AppStore()
        let a = Song(source: "kw", songId: "recent-a", title: "A", artist: "x",
                     album: "", duration: 1, picUrl: "", lrcUrl: "")
        let b = Song(source: "kw", songId: "recent-b", title: "B", artist: "x",
                     album: "", duration: 1, picUrl: "", lrcUrl: "")
        store.removeRecent(at: IndexSet(integersIn: 0..<store.recent.count))
        store.recordRecentForTesting(a)
        store.recordRecentForTesting(b)
        store.recordRecentForTesting(a)
        #expect(store.recent.map { $0.songId } == ["recent-a", "recent-b"])
        #expect(store.recent.count == 2)
    }
}

@Suite("播放器：CDN 请求头注入与流加载")
struct PlayerHeadersTests {

    @Test("各平台音频直链所需 Referer 映射正确")
    func audioHeadersByPlatform() {
        #expect(AppStore.audioHeaders(for: "wy", url: "https://x/1.mp3")["Referer"] == "https://music.163.com")
        #expect(AppStore.audioHeaders(for: "kw", url: "https://x/1.mp3")["Referer"] == "http://www.kuwo.cn/")
        #expect(AppStore.audioHeaders(for: "tx", url: "https://x/1.mp3")["Referer"] == "https://y.qq.com/")
        // 未知平台用同域名 Referer 兜底。
        let fallback = AppStore.audioHeaders(for: "custom", url: "https://cdn.example.com/1.mp3")
        #expect(fallback["Referer"] == "https://cdn.example.com/")
        #expect(fallback["User-Agent"]?.contains("iPhone") == true)
    }

    @Test("本地缓存文件名按 URL 稳定派生：相同 URL 一致、不同 URL 互异、长度固定")
    func cacheFileNameStable() {
        let a = AudioPlayer.stableName("https://m7.music.126.net/x.mp3")
        let b = AudioPlayer.stableName("https://m7.music.126.net/x.mp3")
        #expect(a == b)
        #expect(a.count == 16)
        #expect(AudioPlayer.stableName("https://other.cdn/1.mp3") != a)
    }
}
