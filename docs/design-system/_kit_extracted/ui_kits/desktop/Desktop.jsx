/* Grit — Desktop UI Kit · Shell
   The desktop environment: top menu bar, draggable-feeling windows
   (focus/close/minimize), and the floating dock. Window management is
   cosmetic-but-interactive: open from dock, focus by click, close. */
(function () {
  const NS = window.NexusOSDesignSystem_497743;
  const { Window, Dock, IconButton, Badge } = NS;
  const { FilesApp, TerminalApp, SettingsApp, MonitorApp } = window.GritApps;
  const I = (n, style) => React.createElement('i', { 'data-lucide': n, style });

  const APPS = {
    files:    { title: 'Files — Home',     icon: 'folder',          render: FilesApp,    w: 560, h: 380, x: 90,  y: 70 },
    terminal: { title: 'Terminal',          icon: 'square-terminal', render: TerminalApp, w: 520, h: 320, x: 300, y: 150 },
    settings: { title: 'System Settings',   icon: 'settings',        render: SettingsApp, w: 540, h: 420, x: 180, y: 90 },
    monitor:  { title: 'System Monitor',    icon: 'activity',        render: MonitorApp,  w: 500, h: 420, x: 360, y: 60 },
  };

  function TopBar({ clock }) {
    return React.createElement('div', {
      style: { position: 'absolute', top: 0, left: 0, right: 0, height: 34, zIndex: 500,
        display: 'flex', alignItems: 'center', gap: 18, padding: '0 14px',
        background: 'var(--glass-tint)', backdropFilter: 'var(--blur-thin)', WebkitBackdropFilter: 'var(--blur-thin)',
        borderBottom: '1px solid var(--border)', boxShadow: 'var(--edge-light)' }
    },
      React.createElement('img', { src: '../../assets/logo-grit-mark.svg', style: { width: 16, height: 16 } }),
      React.createElement('span', { style: { font: 'var(--fw-semibold) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-heading)' } }, 'Grit'),
      React.createElement('span', { style: { font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-muted)' } }, 'File'),
      React.createElement('span', { style: { font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-muted)' } }, 'View'),
      React.createElement('span', { style: { font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-muted)' } }, 'Window'),
      React.createElement('div', { style: { flex: 1 } }),
      React.createElement('span', { style: { display: 'inline-flex', color: 'var(--text-body)', width: 15, height: 15 } }, I('wifi')),
      React.createElement('span', { style: { display: 'inline-flex', color: 'var(--text-body)', width: 15, height: 15 } }, I('volume-2')),
      React.createElement('span', { style: { display: 'inline-flex', color: 'var(--grit-success)', width: 15, height: 15 } }, I('battery-full')),
      React.createElement('span', { style: { font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-mono)', color: 'var(--text-heading)', letterSpacing: '0.02em' } }, clock)
    );
  }

  function Desktop() {
    const [open, setOpen] = React.useState(['files', 'monitor']);
    const [focus, setFocus] = React.useState('files');
    const [pos, setPos] = React.useState(() => {
      const p = {}; Object.keys(APPS).forEach(k => p[k] = { x: APPS[k].x, y: APPS[k].y }); return p;
    });
    const [clock, setClock] = React.useState('');
    const drag = React.useRef(null);

    React.useEffect(() => {
      const tick = () => setClock(new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
      tick(); const id = setInterval(tick, 10000); return () => clearInterval(id);
    }, []);
    React.useEffect(() => { window.lucide && window.lucide.createIcons(); });

    const launch = (id) => {
      if (!APPS[id]) return;
      setOpen((o) => o.includes(id) ? o : [...o, id]);
      setFocus(id);
    };
    const close = (id) => {
      setOpen((o) => o.filter((x) => x !== id));
    };

    // drag handlers (move whole window by titlebar)
    const onMouseDown = (id, e) => {
      setFocus(id);
      drag.current = { id, sx: e.clientX, sy: e.clientY, ox: pos[id].x, oy: pos[id].y };
    };
    React.useEffect(() => {
      const move = (e) => {
        if (!drag.current) return;
        const d = drag.current;
        setPos((p) => ({ ...p, [d.id]: { x: Math.max(0, d.ox + (e.clientX - d.sx)), y: Math.max(34, d.oy + (e.clientY - d.sy)) } }));
      };
      const up = () => { drag.current = null; };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
      return () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); };
    }, []);

    const dockItems = Object.keys(APPS).map((id) => ({
      id, icon: I(APPS[id].icon), label: APPS[id].title.split(' —')[0].split(' ')[0],
      active: focus === id && open.includes(id), running: open.includes(id),
    }));

    return React.createElement('div', { className: 'grit-wall grit-wall-depth', style: { position: 'absolute', inset: 0, overflow: 'hidden' } },
      React.createElement(TopBar, { clock }),

      open.map((id, i) => {
        const a = APPS[id];
        const isF = focus === id;
        return React.createElement('div', {
          key: id,
          onMouseDown: () => setFocus(id),
          style: { position: 'absolute', left: pos[id].x, top: pos[id].y, zIndex: isF ? 100 + i : 10 + i, width: a.w }
        },
          React.createElement('div', { onMouseDown: (e) => onMouseDown(id, e), style: { cursor: 'grab' } },
            React.createElement(Window, {
              title: a.title, icon: I(a.icon), width: a.w, height: a.h, active: isF,
              onClose: (e) => { e && e.stopPropagation && e.stopPropagation(); close(id); },
              onMinimize: () => close(id), onMaximize: () => {},
              bodyStyle: { cursor: 'default' },
            }, React.createElement('div', { onMouseDown: (e) => e.stopPropagation(), style: { height: '100%' } }, React.createElement(a.render)))
          )
        );
      }),

      React.createElement('div', { style: { position: 'absolute', left: '50%', bottom: 16, transform: 'translateX(-50%)', zIndex: 400 } },
        React.createElement(Dock, { items: dockItems, onItemClick: (id) => (open.includes(id) ? setFocus(id) : launch(id)) })
      )
    );
  }

  window.GritDesktop = Desktop;
})();
