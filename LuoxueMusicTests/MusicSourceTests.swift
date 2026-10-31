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
        #expect(decoded.script.contains("module.exports"))
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
}
