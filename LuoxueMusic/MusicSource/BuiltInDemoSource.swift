import Foundation

enum BuiltInDemoSource {
    /// 一段符合洛雪格式的内置演示音源脚本（module.exports 结构不变）。
    ///
    /// 真实音源由使用者在“音源管理”中自行导入，与洛雪保持一致：App 本身不内置
    /// 任何平台的版权音频源。演示音源只用一段公开可播放的示例音频，用于验证运行时。
    static let script = """
    const source = {
      name: '演示音源',
      version: '1.0.0',
      platform: 'demo',
      author: 'LuoxueMusic',
      async musicSearch(query, page = 1, limit = 30) {
        return [
          { songmid: 'demo-1', songname: query + ' - 示例曲目一', singer: '演示歌手', albumname: '演示专辑', interval: 215 },
          { songmid: 'demo-2', songname: query + ' - 示例曲目二', singer: '演示歌手', albumname: '演示专辑', interval: 198 }
        ];
      },
      async getMusicUrl(musicInfo) {
        return { url: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3' };
      },
      async getLyric(musicInfo) {
        return { lyric: '[00:00.00]这是演示音源的示例歌词\\n[00:05.00]导入真实洛雪音源即可播放真实歌曲' };
      }
    };
    module.exports = source;
    """

    static func makeMusicSource() -> MusicSource {
        MusicSource(name: "演示音源", version: "1.0.0", platform: "demo",
                    author: "LuoxueMusic", script: script, enabled: true)
    }
}
