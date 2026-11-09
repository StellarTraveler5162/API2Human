import Foundation

/// 语音识别热词：内置的面试常用中文术语 + 角色卡技能档里的中文词
///
/// 实测（TTS 合成的面试题，权重 3）：
/// - "三四握手"→"三次握手"、"晋城和县城"→"进程和县城" 能纠正；"携程"→"协程" 纠不过来（留给文本纠错）
/// - 权重 4 起，普通句子里的"进城"会被改成"进程"，所以默认 3
/// - 英文热词会吞掉邻近的词，只用中文
enum Hotwords {
    static let defaultScore: Float = 3.0
    static let maxCount = 120

    static let builtIn: [String] = [
        "三次握手", "四次挥手", "进程", "线程", "协程", "线程池", "线程安全", "多线程", "死锁", "互斥锁", "读写锁",
        "分布式锁", "分布式事务", "分库分表", "读写分离", "主从复制", "索引", "联合索引", "回表", "覆盖索引",
        "事务隔离", "幻读", "脏读", "缓存击穿", "缓存穿透", "缓存雪崩", "布隆过滤器", "消息队列", "幂等",
        "限流", "熔断", "降级", "负载均衡", "一致性哈希", "哈希表", "红黑树", "链表", "二叉树", "堆排序",
        "快速排序", "归并排序", "动态规划", "贪心", "回溯", "时间复杂度", "空间复杂度", "垃圾回收",
        "内存泄漏", "虚拟内存", "微服务", "容器化", "灰度发布", "高并发", "高可用", "注意力机制", "微调",
        "向量数据库", "召回", "埋点",
    ]

    /// 内置词 + 背景资料里技能档（"- 熟练：…" "- 用过：…" "- 了解或没用过：…"）中的中文词，去重后最多 maxCount 个
    static func list(context: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in builtIn + fromSkillLines(context) where seen.insert(w).inserted {
            out.append(w)
        }
        return Array(out.prefix(maxCount))
    }

    static func fromSkillLines(_ text: String) -> [String] {
        let tiers = #"^\s*[-*]\s*(熟练|精通|用过|了解|了解或没用过|没用过)[^：:]*[：:]"#
        var words: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard let r = s.range(of: tiers, options: .regularExpression) else { continue }
            // 括号里的程度说明（"（只看过原理）""（简单用过）"）整段去掉；括号外的"简单工厂""只读事务"是术语，要留
            let rest = String(s[r.upperBound...]).replacingOccurrences(
                of: #"[（(][^）)]*(只|看过|会写|一点|简单|了解)[^）)]*[）)]"#, with: "、", options: .regularExpression)
            // 只取连续 2~8 个汉字的片段，例如"分库分表""慢查询优化"
            var run = ""
            func flush() {
                if (2...8).contains(run.count), !stopwords.contains(run), !narrative.contains(where: run.contains) { words.append(run) }
                run = ""
            }
            for ch in rest {
                if ch.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) { run.append(ch) } else { flush() }
            }
            flush()
        }
        return words
    }

    /// 叙述性的话（"做过大型项目""负责过支付"）不是术语，当热词只会把普通说法往这上面拉
    private static let narrative = ["做过", "参与", "负责", "经验", "使用过", "接触", "熟悉", "看过"]
    private static let stopwords: Set<String> = ["只看过原理", "只会写", "部署", "了解", "用过", "熟练", "原理", "看过", "没用过", "一点"]

    /// 这个模型的词表里每个汉字都是带词首标记的独立 token（"▁进"），BPE 直接编"进程"会得到查不到的"程"，
    /// 热词整条失效。所以汉字之间加空格，让每个字单独编码。
    static func encodeForModel(_ word: String) -> String {
        var out = ""
        var prevCJK = false
        for ch in word.trimmingCharacters(in: .whitespaces) {
            let cjk = ch.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
            if !out.isEmpty, cjk || prevCJK, out.last != " ", ch != " " { out.append(" ") }
            out.append(ch)
            prevCJK = cjk
        }
        return out
    }
}
