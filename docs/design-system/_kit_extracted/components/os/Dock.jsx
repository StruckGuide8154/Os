import React from 'react';

/**
 * Grit — Dock
 * The redesigned taskbar: a floating glass bar of app tiles. Active
 * apps get a neon underline indicator; hover lifts the tile. Pass an
 * array of items; the component is presentational (controlled).
 */
export function Dock({
  items = [],            // [{ id, icon, label, active, running }]
  onItemClick,
  style,
  ...rest
}) {
  return (
    <div
      style={{
        display: 'inline-flex',
        alignItems: 'flex-end',
        gap: 6,
        padding: '8px 10px',
        background: 'var(--glass-tint-2)',
        backdropFilter: 'var(--blur-glass)',
        WebkitBackdropFilter: 'var(--blur-glass)',
        border: '1px solid var(--border-control)',
        borderRadius: 'var(--r-2xl)',
        boxShadow: 'var(--shadow-lg), var(--edge-light)',
        ...style,
      }}
      {...rest}
    >
      {items.map((it) => (
        <DockItem key={it.id} item={it} onClick={() => onItemClick && onItemClick(it.id)} />
      ))}
    </div>
  );
}

function DockItem({ item, onClick }) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);
  return (
    <button
      type="button"
      aria-label={item.label}
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => { setHover(false); setPress(false); }}
      onMouseDown={() => setPress(true)}
      onMouseUp={() => setPress(false)}
      style={{
        position: 'relative',
        display: 'inline-flex',
        flexDirection: 'column',
        alignItems: 'center',
        gap: 5,
        padding: 0,
        border: 'none',
        background: 'transparent',
        cursor: 'pointer',
      }}
    >
      {hover && (
        <span style={{
          position: 'absolute', bottom: 'calc(100% + 8px)', left: '50%', transform: 'translateX(-50%)',
          padding: '5px 9px', borderRadius: 'var(--r-sm)',
          background: 'var(--surface-active)', border: '1px solid var(--border-control)',
          color: 'var(--text-heading)', font: 'var(--fw-medium) var(--fs-xs)/1 var(--font-ui)',
          whiteSpace: 'nowrap', boxShadow: 'var(--shadow-pop)', pointerEvents: 'none',
        }}>{item.label}</span>
      )}
      <span
        style={{
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: 46,
          height: 46,
          borderRadius: 'var(--r-lg)',
          background: item.active ? 'var(--accent-fill)' : 'var(--surface-panel)',
          border: '1px solid',
          borderColor: item.active ? 'var(--focus-ring)' : 'var(--border)',
          color: item.active ? 'var(--text-accent)' : 'var(--text-body)',
          boxShadow: item.active ? 'var(--glow-soft)' : (hover ? 'var(--shadow-md)' : 'var(--shadow-xs)'),
          transform: press ? 'scale(0.92)' : (hover ? 'translateY(-6px) scale(1.06)' : 'none'),
          transition: 'transform var(--dur-2) var(--ease-spring), box-shadow var(--dur-2) var(--ease-out), background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)',
        }}
      >
        <span style={{ display: 'inline-flex', width: 22, height: 22 }}>{item.icon}</span>
      </span>
      <span style={{
        width: 5, height: 5, borderRadius: '50%',
        background: item.running ? 'var(--accent)' : 'transparent',
        boxShadow: item.running ? '0 0 6px var(--accent)' : 'none',
        transition: 'background var(--dur-2) var(--ease-out)',
      }} />
    </button>
  );
}
