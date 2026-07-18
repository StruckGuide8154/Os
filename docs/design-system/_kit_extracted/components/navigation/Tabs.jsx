import React from 'react';

/**
 * Grit — Tabs
 * Segmented control with a sliding accent indicator. Controlled via
 * `value`/`onChange`. Items: { id, label, icon? }.
 */
export function Tabs({
  items = [],
  value,
  onChange,
  size = 'md',          // 'sm' | 'md'
  style,
  ...rest
}) {
  const h = size === 'sm' ? 30 : 36;
  return (
    <div
      role="tablist"
      style={{
        display: 'inline-flex',
        gap: 2,
        padding: 3,
        background: 'var(--surface-input)',
        border: '1px solid var(--border)',
        borderRadius: 'var(--r-md)',
        boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.25)',
        ...style,
      }}
      {...rest}
    >
      {items.map((it) => {
        const sel = it.id === value;
        return (
          <button
            key={it.id}
            role="tab"
            aria-selected={sel}
            onClick={() => onChange && onChange(it.id)}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 7,
              height: h,
              padding: '0 14px',
              border: 'none',
              borderRadius: 'var(--r-sm)',
              background: sel ? 'var(--surface-active)' : 'transparent',
              color: sel ? 'var(--text-heading)' : 'var(--text-muted)',
              boxShadow: sel ? 'var(--shadow-xs), var(--edge-light)' : 'none',
              font: `var(--fw-medium) var(--fs-sm)/1 var(--font-ui)`,
              cursor: 'pointer',
              transition: 'background var(--dur-2) var(--ease-out), color var(--dur-2) var(--ease-out)',
              whiteSpace: 'nowrap',
            }}
          >
            {it.icon && <span style={{ display: 'inline-flex', width: 15, height: 15, color: sel ? 'var(--text-accent)' : 'inherit' }}>{it.icon}</span>}
            {it.label}
          </button>
        );
      })}
    </div>
  );
}
