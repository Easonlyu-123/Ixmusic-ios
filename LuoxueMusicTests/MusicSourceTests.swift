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
}
