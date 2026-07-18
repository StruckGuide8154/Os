import React from 'react';

/**
 * Grit — IconButton
 * Square, icon-only control for toolbars, titlebars and the dock.
 * `tone="accent"` lights it with the neon tint.
 */
export function IconButton({
  icon,
  size = 'md',          // 'sm' | 'md' | 'lg'
  tone = 'neutral',     // 'neutral' | 'accent' | 'danger'
  active = false,
  disabled = false,
  label,                // aria-label (recommended)
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [press, setPress] = React.useState(false);

  const sizes = { sm: 28, md: 34, lg: 42 };
  const dim = sizes[size] || sizes.md;

  const toneColor = {
    neutral: { fg: 'var(--text-body)', fgHover: 'var(--text-heading)', bgHover: 'var(--surface-raised)' },
    accent:  { fg: 'var(--text-accent)', fgHover: 'var(--text-accent)', bgHover: 'var(--accent-fill)' },
    danger:  { fg: 'var(--grit-error)', fgHover: '#D98079', bgHover: 'var(--grit-error-soft)' },
  }[tone];

  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={active}
      disabled={disabled}
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => { setHover(false); setPress(false); }}
      onMouseDown={() => setPress(true)}
      onMouseUp={() => setPress(false)}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        width: dim,
        height: dim,
        borderRadius: 'var(--r-sm)',
        border: '1px solid',
        borderColor: active ? 'var(--border-control)' : 'transparent',
        background: active ? 'var(--accent-fill)' : (hover ? toneColor.bgHover : 'transparent'),
        color: active ? 'var(--text-accent)' : (hover ? toneColor.fgHover : toneColor.fg),
        cursor: disabled ? 'not-allowed' : 'pointer',
        opacity: disabled ? 0.4 : 1,
        transition: 'background var(--dur-2) var(--ease-out), color var(--dur-2) var(--ease-out), transform var(--dur-1) var(--ease-out)',
        transform: press && !disabled ? 'scale(0.9)' : 'none',
        ...style,
      }}
      {...rest}
    >
      <span style={{ display: 'inline-flex', width: Math.round(dim * 0.5), height: Math.round(dim * 0.5) }}>
        {icon}
      </span>
    </button>
  );
}
