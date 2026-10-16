/**
 * dsh-open-project, 浏览器半边：通用设置里的一行「资源管理器右键菜单」。
 *
 * 这是一个客户端插件 bundle。外壳通过 `window.__ModuleLoader__.load({ id, factory })`
 * 注册它，factory 拿到一个 `require`（平台基线模块表，React 在其中），直接返回模块导出。
 *
 * 挂载点是设置通用页的 `settings.general.item` 插槽——与「显示代码工作视图」同一张列表，
 * 因此结构与样式都照抄 ui-settings-general 的 DeveloperToolsRow：左侧标题+说明，右侧开关。
 *
 * 页面只做两件事：
 *   GET  /.dsh-open-project/menu  → 读当前是否已添加菜单项；
 *   POST /.dsh-open-project/menu  → 打勾写入注册表、去勾删除注册表项。
 * 真正的注册表操作在宿主半边的 cli\context-menu.ps1 里，这里不重复实现。
 *
 * 注意：这个文件由宿主原样编进 /plugins 的 combo 脚本并在浏览器里执行，
 * 因此不写 import/export，只依赖 factory 注入的 require。
 */

window.__ModuleLoader__.load({
  id: 'dsh-open-project',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement

    /** 本插件占用的宿主路由。 */
    const ENDPOINT = '/.dsh-open-project/menu'

    /**
     * 界面文案：跟随浏览器语言，中文环境显示中文，其余显示英文。
     * 只在这一处判断，避免把 locale 服务变成硬依赖。
     */
    const isChinese = typeof navigator !== 'undefined' && /^zh\b/iu.test(navigator.language ?? '')
    const TEXT = isChinese
      ? {
          title: '用 DeepSeek Harness 打开',
          description: '在文件夹的右键菜单里增加「用 DeepSeek Harness 打开」，点击后把该文件夹登记为 DSH 项目。只写当前用户的注册表，不需要管理员权限。',
          failed: '操作失败：'
        }
      : {
          title: 'Open in DeepSeek Harness',
          description: 'Adds an “Open in DeepSeek Harness” entry to a folder context menu. Selecting it registers the folder as a DSH project. Writes the current user’s registry only; no administrator rights needed.',
          failed: 'Failed: '
        }

    /** 样式表标识：同一份文档里只注入一次。 */
    const STYLE_TAG_ID = 'dsh-open-project/settings-row.css'

    /**
     * 与通用页保持一致的排版：行内两端对齐、细分隔线、标题 14px、说明 12px 次级色。
     * 类名带前缀，避免与官方模块的样式冲突。
     */
    const CSS = `
.dop-row{border-bottom:.5px solid var(--dsw-alias-border-l2);justify-content:space-between;align-items:center;gap:24px;padding:16px 0;display:flex}
.dop-title{font-size:14px;line-height:20px}
.dop-description{color:var(--dsw-alias-label-secondary);margin-top:4px;font-size:12px;line-height:18px}
.dop-error{color:#e5534b;margin-top:4px;font-size:12px;line-height:18px}
.dop-switch{position:relative;flex:0 0 auto;width:40px;height:22px;padding:0;border:0;border-radius:11px;background:var(--dsw-alias-bg-l3,rgba(128,128,128,.35));cursor:pointer;transition:background .15s ease}
.dop-switch[data-on="true"]{background:var(--dsw-alias-brand-primary,#4d6bfe)}
.dop-switch:disabled{opacity:.5;cursor:default}
.dop-switch span{position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:50%;background:#fff;transition:transform .15s ease}
.dop-switch[data-on="true"] span{transform:translateX(18px)}
`

    /** 把样式注入文档（幂等）。 */
    function installStyles() {
      if (typeof document === 'undefined') return
      if (document.querySelector(`style[data-dsh-plugin-css="${STYLE_TAG_ID}"]`) !== null) return
      const tag = document.createElement('style')
      tag.dataset.dshPluginCss = STYLE_TAG_ID
      tag.textContent = CSS
      document.head.appendChild(tag)
    }

    /** 读一次宿主状态。 */
    async function fetchState(signal) {
      const response = await fetch(ENDPOINT, { method: 'GET', signal, cache: 'no-store' })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      return await response.json()
    }

    /** 写一次宿主状态。 */
    async function putState(enabled) {
      const response = await fetch(ENDPOINT, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ enabled })
      })
      const payload = await response.json().catch(() => ({}))
      if (!response.ok || payload.ok !== true) throw new Error(payload.error ?? `HTTP ${response.status}`)
      return payload
    }

    /**
     * 一个与设置页同构的开关。
     * @param props - checked / disabled / onChange。
     */
    function Switch({ checked, disabled, onChange }) {
      return h('button', {
        type: 'button',
        role: 'switch',
        'aria-checked': checked ? 'true' : 'false',
        className: 'dop-switch',
        'data-on': checked ? 'true' : 'false',
        disabled: disabled === true,
        onClick: () => { onChange(!checked) }
      }, h('span', null))
    }

    /** 通用设置里的这一行。 */
    function OpenProjectRow() {
      const [state, setState] = React.useState({ phase: 'loading', enabled: false, error: '' })

      React.useEffect(() => {
        const controller = new AbortController()
        fetchState(controller.signal)
          .then((payload) => { setState({ phase: 'ready', enabled: payload.enabled === true, error: '' }) })
          .catch((error) => {
            if (controller.signal.aborted) return
            setState({ phase: 'ready', enabled: false, error: String(error?.message ?? error) })
          })
        return () => { controller.abort() }
      }, [])

      const apply = React.useCallback((next) => {
        setState((current) => ({ ...current, phase: 'saving', enabled: next, error: '' }))
        putState(next)
          .then(() => { setState({ phase: 'ready', enabled: next, error: '' }) })
          .catch((error) => {
            // 失败时回读真实状态，避免界面显示成"已生效"。
            fetchState()
              .then((payload) => { setState({ phase: 'ready', enabled: payload.enabled === true, error: String(error?.message ?? error) }) })
              .catch(() => { setState((current) => ({ ...current, phase: 'ready', error: String(error?.message ?? error) })) })
          })
      }, [])

      return h('div', { className: 'dop-row' },
        h('div', null,
          h('div', { className: 'dop-title' }, TEXT.title),
          h('div', { className: 'dop-description' }, TEXT.description),
          state.error !== '' ? h('div', { className: 'dop-error', role: 'alert' }, `${TEXT.failed}${state.error}`) : null
        ),
        h(Switch, {
          checked: state.enabled,
          disabled: state.phase !== 'ready',
          onChange: apply
        })
      )
    }

    /** Cordis 插件名，与 package.json / 宿主半边保持一致。 */
    const name = 'dsh-open-project'

    /**
     * 声明 slots 是必要的：Cordis 会等到注入的服务就绪才激活插件，
     * 少了它，插件可能在插槽注册表存在之前激活，注册直接抛错。
     */
    const inject = ['slots']

    /**
     * 把这一行注册进设置通用页。
     * @param ctx - 客户端插件上下文。
     */
    function apply(ctx) {
      ctx.effect(() => {
        installStyles()
        return ctx.slots.inject('settings.general.item', () => ctx.slots.register(
          {
            name: 'settings.general.item',
            id: 'open-project',
            // 通用页现有两项是 15（显示代码工作视图）与 100（版本号），这里夹在中间。
            order: 50
          },
          OpenProjectRow
        ))
      })
    }

    return { name, inject, apply }
  }
})
