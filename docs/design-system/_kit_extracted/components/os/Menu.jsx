import React from 'react';

/**
 * Grit — Menu
 * Glass popover menu for context menus, app menus and dropdowns.
 * Items: { label, icon?, shortcut?, danger?, disabled?, separator? }.
 * Presentational — position it yourself (e.g. absolute) at the anchor.
 */
export function Menu({
  items = [],
  onSelect,
  width = 220,
  style,
  ...rest
}) {
  return (
    <div
      role="menu"
      style={{
        width,
        padding: 6,
        background: 'var(--glass-tint-2)',
        backdropFilter: 'var(--blur-glass)',
        WebkitBackdropFilter: 'var(--blur-glass)',
        border: '1px solid var(--border-control)',
        borderRadius: 'var(--r-md)',
        boxShadow: 'var(--shadow-pop), var(--edge-light)',
        ...style,
      }}
      {...rest}
    >
      {items.map((it, i) => {
        if (it.separator) {
          return <div key={i} style={{ height: 1, margin: '6px 8px', background: 'var(--border)' }} />;
        }
        return <MenuItem key={i} item={it} onSelect={onSelect} />;
      })}
    </div>
  );
}

function MenuItem({ item, onSelect }) {
  const [hover, setHover] = React.useState(false);
  const danger = item.danger;
  const disabled = item.disabled;
  const fg = disabled ? 'var(--text-faint)' : (danger ? 'var(--grit-error)' : 'var(--text-body)');

  return (
    <button
      type="button"
      role="menuitem"
      disabled={disabled}
      onClick={() => !disabled && onSelect && onSelect(item)}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 10,
        width: '100%',
        height: 32,
        padding: '0 10px',
        border: 'none',
        borderRadius: 'var(--r-sm)',
        background: hover && !disabled ? (danger ? 'var(--grit-error-soft)' : 'var(--accent-fill)') : 'transparent',
        color: hover && !disabled && !danger ? 'var(--text-accent)' : fg,
        cursor: disabled ? 'not-allowed' : 'pointer',
        font: 'var(--fw-medium) var(--fs-sm)/1 var(--font-ui)',
        textAlign: 'left',
        transition: 'background var(--dur-1) var(--ease-out), color var(--dur-1) var(--ease-out)',
      }}
    >
      {item.icon && <span style={{ display: 'inline-flex', width: 16, height: 16, flex: '0 0 auto' }}>{item.icon}</span>}
      <span style={{ flex: 1 }}>{item.label}</span>
      {item.shortcut && (
        <span style={{ font: 'var(--fw-regular) var(--fs-xs)/1 var(--font-mono)', color: 'var(--text-faint)', letterSpacing: '0.04em' }}>{item.shortcut}</span>
      )}
    </button>
  );
}
