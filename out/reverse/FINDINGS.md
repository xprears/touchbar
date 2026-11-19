# 微信深链逆向 —— 阶段性记录（2026-10-09）

目标：给「小程序 / 视频号 / 搜一搜」找可用的入口，取代已废弃的坐标点击方案。

---

## 0. ⚠️ 先说事故：探针误启动了用户的 Parallels Windows 11 虚拟机

不是猜测，证据链完整：

1. 我写了 `tools/probe.py`，逐条跑**裸 `open "<url>"`** 去试候选深链。
2. 清单里有一条 `search://page/miniprogram`。
3. 该条发出的瞬间，Parallels Desktop 被启动，并**恢复了** Windows 11 虚拟机
   （`parallels.log` 首行：`09:58:37 VM process started`，状态机走 `SareCmdResume`，
   是从挂起恢复、不是冷启动；时间与探针跑到第 13 条完全吻合）。

**根因（LaunchServices 数据库硬证据）**：Parallels 为 Windows 应用生成的 Mac 捷径

```
~/Applications (Parallels)/{8ed6f94d-…} Applications.localized/文件资源管理器.app
```

在其 `Info.plist` 里注册了 URL scheme **`search`**（另有 `search-ms`、`explorer.*`）。
`lsregister -dump` 确认：

```
claim id: 5496   rank: Default   bundle: 文件资源管理器 (0x8dc)
bindings: explorer.assocactionid.burnselection:, …, search:, search-ms:
```

`search:` 的 **Default** 处理器就是它、无竞争者 ⇒ 裸 `open "search://…"` 必然走它。

**排除过程**：先确认自己的工具链没碰 Parallels ——
`shared/Scanner.swift` 无任何 `open`；`tools/cli/main.swift` 的 `activate()` 只是
`NSRunningApplication.activate`，`sendKey`/`sendClick` 是 CGEvent，`shoot` 是
`screencapture -R`。**一个都不访问 `~/Applications (Parallels)`。**
真凶是 LaunchServices 的 scheme 抢注。

**已做的修复**：`tools/probe.py` 与 `tools/probe_deeplinks.sh` 全部改成
**`open -b com.tencent.xinWeChat "<url>"`**，强制投递给微信，杜绝 LaunchServices 乱路由。
`candidates.txt` 里危险项已注释并标注。

**顺带查清的其它 scheme 归属**（同一份 dump 统计）：

| scheme | 注册者 |
|---|---|
| `weixin:` | 微信（3 条） |
| `search:` | **Parallels 文件资源管理器（Default）** ← 地雷 |
| `xweb:` | 无人注册（0 条） |
| `chatbotsearch:` | 无人注册（0 条） |

---

## 1. 目标二进制

| 路径 | 大小 | 说明 |
|---|---|---|
| `Contents/Frameworks/wechat.dylib` | 84 KB | **壳**，别在这上面浪费时间 |
| `Contents/Resources/wechat.dylib` | **327 MB** | 真逻辑在这 |

微信 4.1.13 / CFBundleVersion 269602。`Info.plist` 注册 scheme：`xweixin` / `weixin` / `wechat`。

## 2. 静态提取到的真实字面量（已用原始字节复核，是 NUL 分隔的完整串）

```
weixin://resourceid/Search/app.html
weixin://resourceid/AppletDiscover/app.html          ← 小程序发现页
weixin://resourceid/SearchEmotion/app.html
weixin://jump/mainframe/
weixin://dl/jumpredirect_url:%_                      ← 通用跳转（疑似 format 串）
weixin://dl/openinvalid
weixin://private/client_command/
weixin://private/setresult/
weixin://bizmsgmenu?msgmenucontent=…&msgmenuid=…
weixin://kefumenu?kefumenucontent=…
search://page/{miniprogram,officialaccount,servicenotification,wxpay,welehelper,fi}
chatbotsearch://page/chixinteam
xweb://star-page
```

旁证：硬编码公众号 id `gh_3dfda90e39d6`；原生符号 `openWXSearchPage_38e506b7`；
`game.weixin.qq.com` / `standalone` / `embed` / `yuanbao.tencent.com`。

### 静态分析的坑（重要）
该 dylib 的字符串池是 **16 字节定长槽**，长字面量会被截断：

- `help_and_feedbac`（应为 feedback）、`dark_mode_settin`、`backup_and_resto` —— 都正好 16 字符
- `language_setting` 恰好 16 字符所以看起来"完整"

⇒ **静态提取只能当候选，不能当结论**，必须实测 + 原始字节复核。
另：`tools/dump_ctx.py` 报的 `file_off` 在 carry 边界有漂移，只信相对上下文、别信绝对偏移。

## 3. 实测结果（第一轮）

`tools/probe_deeplinks.sh` 跑了 8 条候选：`weixin://`、`jump/mainframe/`、
`resourceid/{Search,AppletDiscover}/app.html`、`dl/jumpredirect_url:…`、`dl/openinvalid`、
`bizmsgmenu`、`kefumenu`。

**结论：全部只把微信切到前台，没有一条跳出可见页面。**

`search://` 不在微信 `Info.plist` 的 `CFBundleURLSchemes` 里 ⇒ 外部 `open` 根本投递不到微信，
它是**微信内部的页面路由**（由 app 内 JSBridge / webview 调用），不是外部入口。

## 4. 已验证可用的观测通道（本机免授权）

| 手段 | 状态 |
|---|---|
| `screencapture -x` | ✅ 有屏幕录制权限，可直接用 |
| `tools/wxscan` / `wxctl bounds` | ✅ 微信窗口坐标 + 前台判断 |
| `tools/wxctl shot` | ✅ 截微信整窗 → `out/wx_full.png` |
| 像素差比对（Pillow） | ✅ 灵敏度已对照：`⌘4` 前后差 **41.28%** |
| `/usr/bin/log show` | ❌ 沙箱拒绝（`Cannot run while sandboxed`） |
| 微信数据目录 / 日志 | ❌ 沙箱拒绝（`Operation not permitted`） |

## 5. 工具与产物

**新增工具**（都在 `tools/`）：

- `scan_urls.py` —— 扫二进制里的可打印串
- `extract_schemes2.py` —— 按 scheme 全量提取 URL（`extract_schemes.py` 是被它取代的旧版）
- `dump_ctx.py` —— 关键字上下文 dump
- `probe.py` —— 逐条实测 + Pillow 像素差判读（**已改安全版**）
- `probe_control.py` —— 探针灵敏度对照（⌘4）

**产物**：`out/reverse/` 下 `urls_*.txt`（各 scheme 全量）、`candidates.txt`、
`shots/`（全屏对照图）、`probe/`（窗口区域对照图）。

## 6. 下一步的可行方向

1. **先判死路**：`search://page/*` 是内部路由，外部基本没戏。别再为它折腾。
2. **值得继续**：`weixin://resourceid/AppletDiscover/app.html` —— 名字直指"小程序发现页"。
   第一轮没反应，可能是**参数缺失**（可试 `?` 附加 query / 走 `weixin://dl/jumpredirect_url:`
   包一层）。要从二进制里找它的参数名和调用点。
3. **换入口思路**：`weixin://dl/jumpredirect_url:%_` 这个通用跳转格式串最值得挖
   —— 顺着它的调用点（附近的 `miniprogramType` / `appbrandusername` 字符串）找参数结构。
4. ~~别复活坐标点击~~ → **这条已翻案，见下面「第二轮」**。

---

# 第二轮（2026-10-09 下午）：深链判死 + 坐标点击翻案

## A. 静态侧修正：两个 URL 是假阳性

先用精确字节检索证明字符串池确实在截断（`dark_mode_setting` 全库 **0 命中**），
再逐串复核：

| 串 | 命中 | 结论 |
|---|---|---|
| `weixin://resourceid/{Search,AppletDiscover,SearchEmotion}/app.html` | 2× | ✅ 真实 |
| `weixin://jump/mainframe/` | 2× | ✅ 真实（以 `/` 结尾 ⇒ 疑似前缀） |
| `weixin://dl/jumpredirect_url:` / `weixin://dl/openinvalid` | 2× | ✅ 真实 |
| `weixin://private/{client_command,setresult}/` | 2× / 4× | ✅ 真实 |
| **`weixin://bizmsgmenu`** | **0×** | ❌ **假阳性** |
| **`weixin://kefumenu`** | **0×** | ❌ **假阳性** |

⇒ **静态提取只能产出候选，必须逐串精确复核。**

## B. 深链判死（21 条实测）

`tools/probe_pages.py`：先采 ⌘1/⌘2/⌘3/⌘4 四页当参照模板，把候选 URL 的结果画面
与模板比对，判"跳到了哪一页"。

坑：第一版自己 `screencapture`，**微信没到前台时会截到别的窗口**（实测截到 WorkBuddy），
判读全废 ⇒ 改用 `wxctl shot`（内部先 activate）并强制校验 `前台=com.tencent.xinWeChat`。

结果：`weixin://jump/mainframe/{chat,contacts,discover,favorites,sns,finder,channels,
miniprogram,appbrand,settings,search,games,files,0,1}` + 三个 `resourceid/*/app.html`
—— **21 条全部无效**，画面停在聊天页。

**结论：微信 Mac 对外部 `weixin://` 就是 no-op。深链路线判死。**

## C. 键盘判死

`tools/keymove_probe.py` 用绿色高亮偏移做客观判据穷举：

- `↓ / → / ← / ↑ / Space / Enter / Tab / ⇧Tab / 2 / 3` → **全部无效**
- `⌘1→149px`（聊天）/ `⌘2→无高亮`（通讯录）/ `⌘3→124px`（收藏）/ `⌘4→76px`（发现）
- **`⌘5–⌘9` 全部无效**（2026-10-05 那次 md5 有差异是内容漂移，误判为"有效果"）

⇒ 发现页列表**不可键盘导航**，菜单里那 4 个快捷键就是全部。

## D. ★ 坐标点击翻案

**微信 Mac 4.x 是 Qt 写的**（二进制里有 `QDesktopServices::openUrl` /
`QOpenUrlHandlerRegistry` / `qtmetadata` / `.qtmimedatabase`），这解释了
`AXPress 元素: 0`、整窗只有 3 个子元素 —— **Qt 自绘控件对 Accessibility 完全不可见**。
AX 与键盘都死 ⇒ 坐标是唯一路径。

**实测证据**：
- 窗口 `916×717` → 点 (423, 747) → **精确打开视频号**
- 窗口 `825×826`（尺寸完全不同）→ 点 (428, 726) → **同样精确打开视频号**

⇒ 「窗口一挪就失效」不成立。真因多半是把 `wxctl click` 要的 **Quartz 左下原点**
坐标与 wxscan 给的 **左上原点**窗口坐标搞混了。

**换算式**：
```
click_x = win.x + 121
click_y_quartz = screenH - (win.y + 距窗口顶部偏移)
```

## E. 校准的关键事实

- 行距**恒定 48px**（跨窗口尺寸稳定）
- 首项偏移**随窗口几何变化**（916×717→75.8px；825×826→55px）⇒ **必须现测**
- **微信会保留发现页上次选中的项**；单独 `⌘4` 回去还是上次那个（曾误测成 171.8px）。
  **`⌘1 → ⌘4` 才会重置回第一项**
- 发现页还会**整列无选中项**（右侧是微信 logo 空闲页），此时绿色高亮判据完全失灵
  ⇒ 改用**行墨迹检测**
- `wxctl key` 只接受**一个**键；`key 1 cmd 4 cmd` 里的 `4` 会被当修饰符吞掉

## F. 产出

| 工具 | 作用 |
|---|---|
| `tools/calib.py` | **自校准**：⌘1→⌘4 → 截图 → 检行 → 写 `out/calib.json` |
| `tools/detect_rows.py` | 行墨迹检测发现页 5 个条目（**不依赖选中态**） |
| `tools/find_highlight.py` | 绿色高亮检测，导出 `detect()` 复用 |
| `tools/keymove_probe.py` | 按键组合能否移动选中项 |
| `tools/probe_pages.py` | 页面对比法判落点（含前台校验） |
| `tools/macho_sections.py` | Mach-O 段表解析 + 偏移反查 |
| `tools/grep_strings.py` | 大二进制正则检索可打印串 |

**`calib.py --verify` 端到端**：检出 `75.8 / 123.2 / 171.5 / 218.5 / 267.5`（行距 47.9，
与历史备忘 75/123/172/219/267 吻合）→ 按算出的坐标点「小程序」→
**实测落点 267.8px，偏差 +0.2px，命中**。

## G. 仍未定

偏移随窗口尺寸变化的**规律**没摸出来（只有 2 个数据点，且宽高同时变，是混淆的）。
两种落地方案待选：

1. **`calib.py` 写文件、App 读**（`out/calib.json`）—— App 不需要屏幕录制权限，
   但窗口尺寸变了要用户手动重跑一次。
2. **App 自己截屏自校准** —— 全自动，但 App 需要屏幕录制权限，且 ad-hoc 签名下
   **每次重编译都会失效**（和辅助功能授权同一个坑）。

---

# 第三轮：`xweixin://` / `wechat://` 补测（用户追问）

**上一轮只测了 `weixin://`，漏了另外两个注册 scheme。补测后结论不变：都是死的。**

## 1. 穷举：微信一共只注册 3 个 scheme

扫全 bundle 所有 `Info.plist`，只有主 `Info.plist` 注册了 URL 类型，且只有：
`xweixin` / `weixin` / `wechat`。辅助 App（`WeChatAppEx` / `WeChatHelper` / 两个 appex）
**一个都没注册**。`lsregister` 里含 weix/wechat 的也只有这 3 个，**Default 全是 WeChat**。

## 2. `wechat://` 是假象

`wechat://` 在 dylib 里有 2 处命中，dump 原始字节发现**都是 `xwechat://filepa` 的子串**
（`xwechat` 非注册 scheme，是内部串且被 16 字节池截断）。
⇒ **不存在真实的 `wechat://` URL。**

## 3. `xweixin` 只是裸 scheme 名

全 327MB 检索，`xweixin` **只有 1 个唯一串**：7 字符裸 `xweixin`，位于一张
**8 字节定长槽**短串表里（邻位是 `/biz` `/ww/` `/app` `dk/l` `dk/s` `ptok` `fcha`
`ex/l` `hgam` `ema_` `ncho` `happ` `uch` 等路由锚点碎片，以及完整的
`wechat:/OpenExte:unknownwxOp`）。`xweixin://…` **0 命中** ⇒ 只用于 scheme 比较。

## 4. 实测 11 条：全无反应

`xweixin://` / `xweixin://jump/mainframe/{chat,}` / `xweixin://resourceid/{Search,AppletDiscover}/app.html` /
`xweixin://dl/{openinvalid,scan}` / `xweixin://scanqrcode` / `wechat://` /
`wechat://jump/mainframe/chat` / `wechat://resourceid/Search/app.html`

判读（`probe_pages.py`，页面对比法）：**11 条全部 0.3% 且数字完全相同 = 纯内容漂移，零反应。**

## 5. 累计

三个 scheme × 32 条路径 = **零效果**。`open` 全部 rc=0（macOS 找到了 handler 并调用），
所以是**微信收到后自己丢掉**，不是没送达。

**未取证**：想用 `/usr/bin/log show` 抓 LaunchServices 路由记录坐实"确实送达"，
但沙箱持续拦截（连 `dangerouslyDisableSandbox` 也一样）。

**唯一残余假设**：**冷启动投递**（微信没在跑时由 URL 拉起）。处理代码同一份，
大概率一样无效；要测必须先退微信，有重新扫码登录风险，**未做**。

---

# 第四轮：严格版重测（用户质疑「可能是你在操作电脑」）

**质疑成立，前几轮探针有真实缺陷**：① 跟很久以前采的参照模板比，噪声 0.3%~19%；
② 无干扰检测，用户在采样期间动电脑则采样作废但无人知晓。

**修法** —— 新工具 `tools/probe_strict.py`：

1. 每采样前后校验「前台仍是微信」+「窗口几何不变」，不符则作废重采（最多 3 次）
2. 插一条伪造 URL `weixin://__no_such_path__` 当噪声基线
3. 开跑前 + 收尾各做一次 ⌘4 阳性对照
4. 判定量改为**即时前后对比**（⌘1 归位 → 采 A → 发 URL → 采 B），不再跟旧模板比

**结果（本次运行可信）**：

```
阳性对照(前)  ⌘4 → 52.4%
噪声基线      0.00% / 0.00%      ← 伪造 URL 零变化
16 条候选     全部 0.00% ~ 0.01%
阳性对照(后)  ⌘4 → 52.4%
```

**噪声基线 0.00%、阳性对照前后均 52.4%** ⇒ 任何真实反应都会明显跳出，
候选全部贴零点。**干净的判死。**

**投递确认**（把"送达"钉死）：

```
open -b com.tencent.xinWeChat "weixin://jump/mainframe/chat"   → rc=0 无输出
open -b com.apple.finder        "weixin://jump/mainframe/chat" → rc=1  -10820 失败
open "zzz_no_such_scheme://x"                                  → rc=1
```

⇒ `open -b` 的 rc **有真实判别力**，微信那条 rc=0 是**真的成功派发**。
**微信收到 URL 后自己丢掉。**

产物：`tools/probe_strict.py`、清单 `out/reverse/strict_list.txt`、截图 `out/reverse/strict/`。
