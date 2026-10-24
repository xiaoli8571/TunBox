# G9/G10/G11 路由接线规格（pages-build → theme-shell）

> 供 theme-shell 落地。三个页面/面板本体已交付、自包含、`default export React.FC`，
> 且 `typecheck`/`lint:check`/`format:check` 已全绿。**只剩路由接线**。
> 接线涉及 `App.tsx` / `routes/**` / `shared/types.d.ts` / `shared/appConfig.ts`
> —— 都在 pages-build 的写范围之外，故由 theme-shell 执行。

## 0. 交付物一览（已在仓库里）

| 文件                                          | 导出                                     | 说明                                     |
| --------------------------------------------- | ---------------------------------------- | ---------------------------------------- |
| `src/renderer/src/pages/app-routing.tsx`      | `default React.FC`                       | G9 应用分流（推入式子页，自带 BasePage）  |
| `src/renderer/src/pages/site-routing.tsx`     | `default React.FC<{initialKind?}>`       | G10 网站分流（推入式子页，自带 BasePage） |
| `src/renderer/src/components/tunbox/diagnostics-sheet.tsx` | `default React.FC<{isOpen, onClose}>` | G11 诊断抽屉（受控浮层，**不是路由页**） |
| `src/renderer/src/components/settings/tunbox-routing.tsx` | `default React.FC`           | 设置页两个入口行（**已接进 settings.tsx**）|
| `src/renderer/src/utils/{app,site}-routing.ts` | 纯策略模块                              | 校验/规则生成/排序，带 93 条单测          |

**已经完成、theme-shell 不用管的接线**：
- `pages/settings.tsx` 已 `<TunBoxRouting />`（在我的写范围内）→ 设置页已有
  「应用分流 / 网站分流策略」两个入口行，`navigate('/app-routing')` /
  `navigate('/site-routing')`。
- `pages/network.tsx` 已挂 `<DiagnosticsSheet>`，顶栏有「诊断」按钮拉起。

**所以：只要让 `/app-routing` 与 `/site-routing` 两条路由存在，功能就通。**

---

## 1. `src/renderer/src/routes/route-pages.tsx`（必改）

在既有 lazy 声明区（第 20 行 `TrafficPage` 之后、注释 `// Both modes share...` 之前）插入：

```ts
const AppRoutingPage = createPreloadablePage(() => import('@renderer/pages/app-routing'))
const SiteRoutingPage = createPreloadablePage(() => import('@renderer/pages/site-routing'))
```

在既有导出区（第 42 行 `export const SimpleModule = ...` 之后）插入：

```ts
export const AppRouting = AppRoutingPage.Page
export const SiteRouting = SiteRoutingPage.Page
```

在 `remainingPageLoaders` 数组**末尾**（`TrafficPage.preload` 之后）追加：

```ts
  AppRoutingPage.preload,
  SiteRoutingPage.preload
```

> 说明：追加到末尾而不是插中间，是为了不改动既有预加载的先后顺序
> （首屏体验相关，动了没收益）。两个页面都不在首屏路径上。

**不要**给它们加 `void X.preload()` —— 那是默认落地页才做的事。

## 2. `src/renderer/src/routes/index.tsx`（必改）

第 4-23 行的 import 列表里加两个名字（保持字母序，插入位置按现有顺序）：

```ts
import {
  AppRouting,        // ← 新增（放 Connections 之前）
  Connections,
  DNS,
  ...
  SiteRouting,       // ← 新增（放 Sniffer 之后、SubStore 之前）
  Sniffer,
  SubStore,
  ...
} from './route-pages'
```

在 `routes` 数组里加两条（位置建议紧邻相关页，语义分组）：

```ts
  {
    path: '/app-routing',
    element: <AppRouting />
  },
  {
    path: '/site-routing',
    element: <SiteRouting />
  },
```

建议插在 `/rules` 之后（分流策略与规则同属「订阅页签的运行策略」，放在一起便于阅读）：

```ts
  {
    path: '/rules',
    element: <Rules />
  },
  // ↓ 新增
  {
    path: '/app-routing',
    element: <AppRouting />
  },
  {
    path: '/site-routing',
    element: <SiteRouting />
  },
  // ↑ 新增
  {
    path: '/resources',
    element: <Resources />
  },
```

**注意**：`site-routing.tsx` 支持 `initialKind` prop。若要按 TunBox 的做法带
`kind` 参数深链（TunBox 用 `pushUrl('pages/SiteRoutingPage', {kind})`），
可写成：

```tsx
element: <SiteRouting initialKind="direct" />
```

不过 setup 页的两个入口都进默认（proxy），**当前不需要**。留作后续扩展点。

## 3. `src/renderer/src/components/tunbox/tab-config.ts`（建议改）

`ROUTE_PREFIX_TO_TAB` 数组加两条，让底栏在子页上仍高亮正确页签：

```ts
  ['/app-routing', 'settings'],    // 应用分流属于「设置」页签（TunBox：SettingsPage → pushUrl）
  ['/site-routing', 'settings'],   // 网站分流策略同上
```

依据：TunBox 的 `SettingsPage.ets:403 / :427` 是这两个页的**唯一**调用点，
即它们在信息架构上属于设置页签的推入式子页（contract §1 树）。

**不加的后果**：`getTabByPath` 会兜底成 `'home'`，用户从设置进子页后底栏会错误
高亮「主页」。功能不受影响，但属观感 bug。

## 4. `SiderCardKey` / 侧栏（**不需要改**）

`app-routing` / `site-routing` **不是侧栏卡**，是推入式子页 —— 与 TunBox 一致
（contract §0.3：子页用 `router.pushUrl`，不进页签/不进侧栏卡清单）。

因此：
- **不要**往 `src/shared/types.d.ts:5` 的 `SiderCardKey` 加 key；
- **不要**往 `src/shared/appConfig.ts:13` 的 `DEFAULT_SIDER_ORDER` 加项；
- **不要**往 `components/sider/sider-cards.tsx` 的 `componentMap` 加项。

加了反而违反 contract 附录 B 红线 1（不改功能排布）—— 侧栏是 Clash Party 的
「页签子页清单」，加卡会改变 15 张卡的可达性语义。

## 5. `App.tsx`（**不需要改**）

诊断抽屉已由 `pages/network.tsx` 自己挂载（顶栏按钮控制），**不是全局浮层**，
所以 `App.tsx` 不需要任何改动。

> 📌 若后续要把诊断入口改到主页「告警条」（contract §2.10 原文的入口位置），
> 那需要 theme-shell 在主页壳里挂一次 `<DiagnosticsSheet>`。当前落点是 network
> 顶栏 —— 这是**因为主页壳（`MainPage`/`FloatingBottomBar`）归 theme-shell**，
> pages-build 无法在主页壳上加入口，只能挂在最接近「主页运行态」的 network 页。
> 等主页壳定型后可以把入口搬过去（面板本体不用改，只挪挂载点）。

---

## 6. 接线后的验证清单

```powershell
cd C:\Worker\clash-party-src
pnpm run typecheck && pnpm run lint:check && pnpm run format:check
```

手动冒烟（`pnpm run dev`）：
1. 设置页 → 看到「分流」卡（两行：应用分流 / 网站分流策略，副标题带实时摘要）。
2. 点「应用分流」→ 进 `/app-routing`，底栏仍高亮「设置」；切换三态、勾选、
   添加（弹窗输入 `chrome.exe`）、保存 → 返回设置页，副标题数字跟着变。
3. 点「网站分流策略」→ 进 `/site-routing`；添加 `example.com` 到代理名单，
   切到直连标签再添加 `example.com` → 应被拒并 toast「已在另一份名单」。
4. network 页顶栏「诊断」→ 78% 底部抽屉拉起，链路自检 4 项出结论，
   切「内核日志」tab 看到内核实时日志，点「复制脱敏报告」→ toast 成功。

---

## 7. 有意与 TunBox 分歧之处（不是遗漏，请勿"修正"）

| 项                | TunBox                                | 本实现                                                                 | 原因                                                                   |
| ----------------- | ------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| 应用标识          | 鸿蒙 `bundleName`，VPN want 参数接管  | mihomo `PROCESS-NAME` / `PROCESS-PATH`                                 | Windows 无 HarmonyOS VPN 按包名接管机制                                 |
| 应用校验正则      | `^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$` | Windows 进程名/路径形状                                    | 原正则会判**全部**合法 Windows 条目为非法（有意改，已注释）             |
| 应用候选来源      | 常用目录 + 手动名单                   | 预置进程 + 手填 + 从 `mihomoConnections` 发现的活跃进程                 | 诚实口径一致（TunBox 自认读不到完整安装列表），本实现给真实观测到的进程 |
| 自检项数          | 10 项探针                             | 4 项（appIpc / coreApi / egress / runtime）                            | 只有这 4 项的接口真实存在；凑数会变成假绿                              |
| 「运行日志」tab 内容 | `AppLogger.dump()` 应用日志文件    | 诊断面板自身的事件记录（自检结论/探针异常/重启动作）                     | Clash Party 无读应用日志文件的 IPC（已核 `preload/index.ts` 全通道）    |
| 广告拦截规则入口  | 独立 pushUrl(`RulesPage`)             | 不重复建入口                                                           | Clash Party 规则页已承担，重复入口违反「不新增未列出区块」             |
| 存储              | AppSettings                           | `localStorage`（`tunbox-app-routing` / `tunbox-site-routing`）         | 改 `shared/` 超出 pages-build 写范围；见下方待办                        |

### 待办（跨范围，建议 Lead 立项）

`localStorage` 只是**渲染层暂存**，两条内存态设置还没进 `IAppConfig`。要真正生效需要：

1. `src/shared/types.d.ts` 的 `IAppConfig` 加：
   ```ts
   appRoutingMode: 'all' | 'include' | 'exclude'
   appRoutingIncluded: string[]
   appRoutingExcluded: string[]
   appRoutingNeedsReview: boolean
   forceProxySites: string[]
   forceDirectSites: string[]
   forceBlockSites: string[]
   ```
2. `src/shared/appConfig.ts` 加对应 `DEFAULT_*`。
3. `src/main/resolve/**` 的配置生成器把 `buildAppRules()` / `buildSiteRules()`
   的输出插进 `rules:` 段（**block 段必须在 proxy/direct 之前**——函数已按此顺序返回）。
4. 两个页面的读写从 `localStorage` 换成 `patchAppConfig`。
   （`utils/*-routing.ts` 是纯函数，不用改；页面里只有读写两处。）

**这不是本轮的阻塞项**：页面排布、交互、校验全部按契约落地了，只是持久化层
暂在渲染进程。
