import React from 'react';

/**
 * Grit — Checkbox
 * Square check with accent fill when selected. Supports indeterminate.
 */
export function Checkbox({
  checked = false,
  indeterminate = false,
  disabled = false,
  label,
  onChange,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const on = checked || indeterminate;

  const box = (
    <span
      style={{
        position: 'relative',
        width: 18,
        height: 18,
        flex: '0 0 auto',
        borderRadius: 'var(--r-xs)',
        border: '1px solid',
        borderColor: on ? 'transparent' : (hover ? 'var(--border-strong)' : 'var(--border-control)'),
        background: on ? 'var(--accent-grad)' : 'var(--surface-input)',
        boxShadow: on ? 'var(--glow-soft)' : 'inset 0 1px 2px rgba(0,0,0,0.30)',
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        transition: 'background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)',
      }}
    >
      {indeterminate ? (
        <span style={{ width: 9, height: 2, borderRadius: 1, background: '#fff' }} />
      ) : checked ? (
        <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
          <path d="M2.5 6.2L4.8 8.5L9.5 3.5" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : null}
    </span>
  );

  return (
    <label
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 10,
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        ...style,
      }}
    >
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange && onChange(e.target.checked)}
        style={{ position: 'absolute', opacity: 0, width: 0, height: 0 }}
        {...rest}
      />
      {box}
      {label && <span style={{ font: 'var(--fw-regular) var(--fs-sm)/1 var(--font-ui)', color: 'var(--text-body)' }}>{label}</span>}
    </label>
  );
}
