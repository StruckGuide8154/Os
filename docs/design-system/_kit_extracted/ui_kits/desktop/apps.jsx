/* Grit — Desktop UI Kit · App surfaces
   Cosmetic recreations of the redesigned built-in apps. They compose
   the design-system primitives (window.<NS>) and Lucide icons. */
(function () {
  const NS = window.NexusOSDesignSystem_497743;
  const { Button, IconButton, Input, Switch, Slider, Tabs, Badge, Card, ProgressBar, Avatar } = NS;
  const I = (n, style) => React.createElement('i', { 'data-lucide': n, style });

  /* ---------------- Files ---------------- */
  function FilesApp() {
    const places = [
      { ic: 'house', label: 'Home' },
      { ic: 'folder', label: 'Documents' },
      { ic: 'download', label: 'Downloads' },
      { ic: 'code', label: 'Projects' },
      { ic: 'image', label: 'Pictures' },
    ];
    const [sel, setSel] = React.useState('grit-kernel');
    const files = [
      { n: 'grit-kernel', t: 'folder', meta: '12 items', d: 'Today 09:14' },
      { n: 'bootloader', t: 'folder', meta: '4 items', d: 'Yesterday' },
      { n: 'GritHL.md', t: 'file-text', meta: '18 KB', d: 'Jun 14' },
      { n: 'desktop-shell.c', t: 'file-code', meta: '42 KB', d: 'Jun 12' },
      { n: 'theme.dark.xml', t: 'file-code', meta: '1.2 KB', d: 'Jun 10' },
      { n: 'boot.log', t: 'file', meta: '8 KB', d: 'Jun 09' },
    ];
    return React.createElement('div', { style: { display: 'flex', height: '100%', minHeight: 0 } },
      // sidebar
      React.createElement('div', { style: { width: 168, flex: '0 0 auto', background: 'var(--surface-app)', borderRight: '1px solid var(--border)', padding: 10, display: 'flex', flexDirection: 'column', gap: 2 } },
        React.createElement('div', { className: 'grit-label', style: { padding: '6px 8px 8px' } }, 'Places'),
        places.map((p) => React.createElement('div', {
          key: p.label,
          style: { display: 'flex', alignItems: 'center', gap: 10, padding: '7px 8px', borderRadius: 'var(--r-sm)', color: 'var(--text-body)', cursor: 'pointer', font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)' }
        }, React.createElement('span', { style: { width: 16, height: 16, display: 'inline-flex', color: 'var(--text-muted)' } }, I(p.ic)), p.label))
      ),
      // listing
      React.createElement('div', { style: { flex: 1, minWidth: 0, overflow: 'auto', padding: 8 } },
        React.createElement('div', { style: { display: 'grid', gridTemplateColumns: '1fr 90px 110px', padding: '4px 12px 8px', color: 'var(--text-faint)' } },
          React.createElement('span', { className: 'grit-label' }, 'Name'),
          React.createElement('span', { className: 'grit-label' }, 'Size'),
          React.createElement('span', { className: 'grit-label' }, 'Modified')
        ),
        files.map((f) => React.createElement('div', {
          key: f.n,
          onClick: () => setSel(f.n),
          style: { display: 'grid', gridTemplateColumns: '1fr 90px 110px', alignItems: 'center', padding: '9px 12px', borderRadius: 'var(--r-sm)', cursor: 'pointer',
            background: sel === f.n ? 'var(--accent-fill)' : 'transparent' }
        },
          React.createElement('span', { style: { display: 'flex', alignItems: 'center', gap: 10, color: sel === f.n ? 'var(--text-accent)' : 'var(--text-heading)', font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)' } },
            React.createElement('span', { style: { width: 16, height: 16, display: 'inline-flex', color: f.t === 'folder' ? 'var(--accent)' : 'var(--text-muted)' } }, I(f.t)), f.n),
          React.createElement('span', { style: { font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)', color: 'var(--text-muted)' } }, f.meta),
          React.createElement('span', { style: { font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)', color: 'var(--text-faint)' } }, f.d)
        ))
      )
    );
  }

  /* ---------------- Terminal ---------------- */
  function TerminalApp() {
    const lines = [
      { p: '$', c: 'gritctl status', out: null },
      { p: '', c: null, out: 'Grit 0.5.0  ·  kernel GritHL  ·  secure-boot OK' },
      { p: '', c: null, out: 'desktop-shell  running   pid 142   gpu GOP' },
      { p: '$', c: 'modprobe grithl --secure', out: null },
      { p: '', c: null, out: '[  ok  ] module verified  ·  signature 0x9F2A…E1' },
      { p: '$', c: '', out: null, cursor: true },
    ];
    return React.createElement('div', { style: { height: '100%', background: 'var(--grit-void)', padding: '14px 16px', overflow: 'auto', font: 'var(--fw-regular) var(--fs-sm)/1.7 var(--font-mono)' } },
      lines.map((l, i) => React.createElement('div', { key: i, style: { whiteSpace: 'pre-wrap' } },
        l.c !== null
          ? React.createElement('span', null,
              React.createElement('span', { style: { color: 'var(--accent)' } }, l.p + ' '),
              React.createElement('span', { style: { color: 'var(--text-heading)' } }, l.c),
              l.cursor ? React.createElement('span', { style: { background: 'var(--accent)', color: 'transparent', borderRadius: 1 } }, '\u00A0') : null)
          : React.createElement('span', { style: { color: l.out && l.out.indexOf('ok') > -1 ? 'var(--grit-success)' : 'var(--text-body)' } }, l.out)
      ))
    );
  }

  /* ---------------- Settings ---------------- */
  function SettingsApp() {
    const [tab, setTab] = React.useState('general');
    const [dark, setDark] = React.useState(true);
    const [wifi, setWifi] = React.useState(true);
    const [animations, setAnim] = React.useState(true);
    const [bright, setBright] = React.useState(72);
    const Row = (label, hint, control) => React.createElement('div', {
      style: { display: 'flex', alignItems: 'center', gap: 16, padding: '14px 4px', borderBottom: '1px solid var(--border)' }
    },
      React.createElement('div', { style: { flex: 1 } },
        React.createElement('div', { style: { font: 'var(--fw-medium) var(--fs-base)/1.3 var(--font-ui)', color: 'var(--text-heading)' } }, label),
        hint ? React.createElement('div', { style: { font: 'var(--fw-regular) var(--fs-sm)/1.4 var(--font-ui)', color: 'var(--text-muted)', marginTop: 2 } }, hint) : null),
      React.createElement('div', { style: { flex: '0 0 auto', minWidth: 160, display: 'flex', justifyContent: 'flex-end' } }, control)
    );
    return React.createElement('div', { style: { padding: 18, overflow: 'auto', height: '100%' } },
      React.createElement('div', { style: { marginBottom: 16 } },
        React.createElement(Tabs, { value: tab, onChange: setTab, items: [
          { id: 'general', label: 'General', icon: I('sliders-horizontal') },
          { id: 'display', label: 'Display', icon: I('monitor') },
          { id: 'network', label: 'Network', icon: I('wifi') },
        ] })),
      Row('Dark appearance', 'Use the dark surface ramp system-wide.', React.createElement(Switch, { checked: dark, onChange: setDark })),
      Row('Interface animations', 'Window, dock and menu motion.', React.createElement(Switch, { checked: animations, onChange: setAnim })),
      Row('Wi-Fi', 'grit-secure · connected', React.createElement(Switch, { checked: wifi, onChange: setWifi })),
      Row('Brightness', null, React.createElement('div', { style: { width: 160 } }, React.createElement(Slider, { value: bright, onChange: setBright }))),
      Row('Accent color', 'The system accent.', React.createElement('div', { style: { display: 'flex', gap: 8 } },
        React.createElement('span', { style: { width: 26, height: 26, borderRadius: '50%', background: 'var(--accent-grad)', boxShadow: 'var(--glow-soft)', border: '2px solid #fff' } }),
        React.createElement('span', { style: { width: 26, height: 26, borderRadius: '50%', background: 'var(--sage-base)' } }),
        React.createElement('span', { style: { width: 26, height: 26, borderRadius: '50%', background: 'var(--slate-base)' } })
      ))
    );
  }

  /* ---------------- System Monitor ---------------- */
  function MonitorApp() {
    const stats = [
      { ic: 'cpu', label: 'CPU', val: 34, tone: 'accent', sub: '8 cores · 2.1 GHz' },
      { ic: 'memory-stick', label: 'Memory', val: 61, tone: 'accent', sub: '4.9 / 8.0 GB' },
      { ic: 'hard-drive', label: 'Disk', val: 48, tone: 'success', sub: '120 / 250 GB' },
      { ic: 'thermometer', label: 'Temp', val: 52, tone: 'warning', sub: '52 °C · nominal' },
    ];
    const procs = [
      { n: 'desktop-shell', cpu: '12.4', mem: '186 MB', s: 'running' },
      { n: 'grit-files', cpu: '3.1', mem: '92 MB', s: 'running' },
      { n: 'grithl-sec', cpu: '1.8', mem: '40 MB', s: 'running' },
      { n: 'gop-compositor', cpu: '8.0', mem: '128 MB', s: 'running' },
    ];
    return React.createElement('div', { style: { padding: 16, overflow: 'auto', height: '100%' } },
      React.createElement('div', { style: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 } },
        stats.map((s) => React.createElement(Card, { key: s.label, padding: 'md' },
          React.createElement('div', { style: { display: 'flex', alignItems: 'center', gap: 9, marginBottom: 10 } },
            React.createElement('span', { style: { width: 16, height: 16, display: 'inline-flex', color: 'var(--text-accent)' } }, I(s.ic)),
            React.createElement('span', { className: 'grit-label' }, s.label),
            React.createElement('span', { style: { marginLeft: 'auto', font: 'var(--fw-semibold) var(--fs-lg)/1 var(--font-ui)', color: 'var(--text-heading)' } }, s.val + '%')),
          React.createElement(ProgressBar, { value: s.val, tone: s.tone }),
          React.createElement('div', { style: { font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)', color: 'var(--text-faint)', marginTop: 8 } }, s.sub)
        ))),
      React.createElement('div', { className: 'grit-label', style: { padding: '4px 2px 8px' } }, 'Processes'),
      procs.map((p) => React.createElement('div', { key: p.n, style: { display: 'grid', gridTemplateColumns: '1fr 70px 90px 90px', alignItems: 'center', padding: '9px 4px', borderBottom: '1px solid var(--border)' } },
        React.createElement('span', { style: { font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-heading)' } }, p.n),
        React.createElement('span', { style: { font: 'var(--fs-xs)/1 var(--font-mono)', color: 'var(--text-muted)' } }, p.cpu + '%'),
        React.createElement('span', { style: { font: 'var(--fs-xs)/1 var(--font-mono)', color: 'var(--text-muted)' } }, p.mem),
        React.createElement('span', { style: { justifySelf: 'end' } }, React.createElement(Badge, { tone: 'success', dot: true }, p.s))
      ))
    );
  }

  window.GritApps = { FilesApp, TerminalApp, SettingsApp, MonitorApp };
})();
