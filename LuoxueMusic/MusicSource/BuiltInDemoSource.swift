import Foundation

enum BuiltInDemoSource {
    /// 一段符合洛雪官方 user-api 的内置演示音源（格式与真实洛雪音源一致）。
    ///
    /// 说明：洛雪音乐本身自带「平台音源」（酷狗/网易云/QQ/酷我/咪咕），搜索与播放都由这些内置
    /// 音源完成；用户「导入的音源」在洛雪体系里通常只负责补齐某些平台的播放/歌词。本演示音源仅用
    /// 一段公开可播放的示例音频，用来验证运行时与搜索/播放链路，不代表任何版权曲库。
    /// 导入真实洛雪音源后即可播放真实歌曲。
    static let script = """
    /**
     * @name 演示音源
     * @description 洛雪官方 user-api 示例，仅用于验证运行时
     * @version 1.0.0
     * @author LuoxueMusic
     * @homepage https://github.com/lyswhut/lx-music-desktop
     */
    const { EVENT_NAMES, on, send } = globalThis.lx;

    // 注册应用 API 请求事件（洛雪官方：处理器只接收 { source, action, info } 且必须返回 Promise）
    on(EVENT_NAMES.request, ({ source, action, info }) => {
      switch (action) {
        // 搜索：info = { searchWord, page, limit }
        case 'music/search': {
          const q = info.searchWord;
          return Promise.resolve([
            { songmid: 'demo-1', songname: q + ' - 示例曲目一', singer: '演示歌手', albumname: '演示专辑', interval: 215 },
            { songmid: 'demo-2', songname: q + ' - 示例曲目二', singer: '演示歌手', albumname: '演示专辑', interval: 198 }
          ]);
        }
        // 获取播放直链：info = { type, musicInfo }；返回 URL 字符串。
        // 官方移动端动作为 musicUrl，music/url 为桌面端别名，两者都兼容。
        case 'musicUrl':
        case 'music/url': {
          return Promise.resolve('https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3');
        }
        // 歌词：info = { musicInfo }；返回 { lyric, tlyric, rlyric, lxlyric }
        case 'lyric': {
          return Promise.resolve({
            lyric: '[00:00.00]这是演示音源的示例歌词\\n[00:05.00]导入真实洛雪音源即可播放真实歌曲',
            tlyric: '', rlyric: '', lxlyric: ''
          });
        }
        // 封面：info = { musicInfo }；返回封面 URL 字符串
        case 'pic': {
          return Promise.resolve('');
        }
      }
    });

    // 初始化完成，告知应用本脚本支持的源
    send(EVENT_NAMES.inited, {
      sources: {
        demo: { name: '演示音源', type: 'music', actions: ['musicUrl', 'lyric', 'pic'], qualitys: ['128k', '320k', 'flac', 'flac24bit'] }
      }
    });
    """

    static func makeMusicSource() -> MusicSource {
        MusicSource(name: "演示音源", version: "1.0.0", platform: "demo",
                    author: "LuoxueMusic", script: script, enabled: true)
    }
}
