import React from 'react';

/**
 * Grit — Button
 * Primary action uses the neon accent gradient with a soft glow.
 * Secondary/ghost/danger map onto the layered surface ramp.
 */
export function Button({
  children,
  variant = 'secondary',   // 'primary' | 'secondary' | 'ghost' | 'danger'
  size = 'md',             // 'sm' | 'md' | 'lg'
  icon = null,             // leading node (e.g. <Icon/>)
  trailingIcon = null,
  disabled = false,
  block = false,
  type = 'button',
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [active, setActive] = React.useState(false);
  const [focus, setFocus] = React.useState(false);

  const sizes = {
    sm: { h: 'var(--ctl-h-sm)', px: '10px', fs: 'var(--fs-xs)', gap: '6px', r: 'var(--r-sm)' },
    md: { h: 'var(--ctl-h-md)', px: '14px', fs: 'var(--fs-sm)', gap: '8px', r: 'var(--r-sm)' },
    lg: { h: 'var(--ctl-h-lg)', px: '20px', fs: 'var(--fs-base)', gap: '9px', r: 'var(--r-md)' },
  };
  const s = sizes[size] || sizes.md;

  const base = {
    display: block ? 'flex' : 'inline-flex',
    width: block ? '100%' : 'auto',
    alignItems: 'center',
    justifyContent: 'center',
    gap: s.gap,
    height: s.h,
    padding: `0 ${s.px}`,
    borderRadius: s.r,
    font: `var(--fw-medium) ${s.fs}/1 var(--font-ui)`,
    letterSpacing: '0.01em',
    cursor: disabled ? 'not-allowed' : 'pointer',
    opacity: disabled ? 0.45 : 1,
    border: '1px solid transparent',
    transition: 'background var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out), box-shadow var(--dur-2) var(--ease-out), transform var(--dur-1) var(--ease-out)',
    transform: active && !disabled ? 'translateY(0.5px) scale(0.985)' : 'none',
    userSelect: 'none',
    whiteSpace: 'nowrap',
  };

  const variants = {
    primary: {
      background: hover && !disabled
        ? 'var(--accent-hover)'
        : 'var(--accent-grad)',
      color: 'var(--on-accent)',
      fontWeight: 'var(--fw-semibold)',
      boxShadow: focus
        ? 'var(--glow-accent)'
        : (hover ? 'var(--glow-soft), var(--edge-light)' : '0 2px 10px -2px var(--focus-ring), var(--edge-light)'),
    },
    secondary: {
      background: active ? 'var(--surface-active)' : (hover ? 'var(--surface-raised)' : 'var(--surface-panel)'),
      color: 'var(--text-heading)',
      borderColor: hover ? 'var(--border-strong)' : 'var(--border-control)',
      boxShadow: focus ? 'var(--ring)' : 'var(--shadow-xs)',
    },
    ghost: {
      background: active ? 'var(--surface-raised)' : (hover ? 'var(--accent-fill)' : 'transparent'),
      color: hover ? 'var(--text-accent)' : 'var(--text-body)',
      borderColor: 'transparent',
      boxShadow: focus ? 'var(--ring)' : 'none',
    },
    danger: {
      background: hover && !disabled ? '#D98079' : 'var(--grit-error)',
      color: '#FBF1F0',
      fontWeight: 'var(--fw-semibold)',
      boxShadow: focus ? '0 0 0 3px rgba(207,111,102,0.40)' : '0 2px 10px -2px rgba(207,111,102,0.40)',
    },
  };

  return (
    <button
      type={type}
      disabled={disabled}
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => { setHover(false); setActive(false); }}
      onMouseDown={() => setActive(true)}
      onMouseUp={() => setActive(false)}
      onFocus={() => setFocus(true)}
      onBlur={() => setFocus(false)}
      style={{ ...base, ...variants[variant], ...style }}
      {...rest}
    >
      {icon && <span style={{ display: 'inline-flex', flex: '0 0 auto' }}>{icon}</span>}
      {children && <span>{children}</span>}
      {trailingIcon && <span style={{ display: 'inline-flex', flex: '0 0 auto' }}>{trailingIcon}</span>}
    </button>
  );
}
