import React from 'react';

/**
 * Grit — Badge
 * Compact status/label pill. `tone` maps to the semantic palette;
 * `dot` prepends a status dot (great for "online / running").
 */
export function Badge({
  children,
  tone = 'neutral',     // 'neutral' | 'accent' | 'success' | 'warning' | 'error'
  variant = 'soft',     // 'soft' | 'solid' | 'outline'
  dot = false,
  style,
  ...rest
}) {
  const tones = {
    neutral: { fg: 'var(--text-body)',    soft: 'var(--surface-input)',  solid: 'var(--surface-active)', dot: 'var(--text-muted)' },
    accent:  { fg: 'var(--text-accent)',  soft: 'var(--accent-fill)',    solid: 'var(--accent)',          dot: 'var(--accent)' },
    success: { fg: 'var(--grit-success)',   soft: 'var(--grit-success-soft)',solid: 'var(--grit-success)',       dot: 'var(--grit-success)' },
    warning: { fg: 'var(--grit-warning)',   soft: 'var(--grit-warning-soft)',solid: 'var(--grit-warning)',       dot: 'var(--grit-warning)' },
    error:   { fg: 'var(--grit-error)',     soft: 'var(--grit-error-soft)',  solid: 'var(--grit-error)',         dot: 'var(--grit-error)' },
  };
  const t = tones[tone] || tones.neutral;

  const variants = {
    soft:    { background: t.soft, color: t.fg, border: '1px solid transparent' },
    solid:   { background: t.solid, color: tone === 'neutral' ? 'var(--text-heading)' : 'var(--text-invert)', border: '1px solid transparent' },
    outline: { background: 'transparent', color: t.fg, border: `1px solid ${t.dot}` },
  };

  return (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 6,
        height: 22,
        padding: '0 9px',
        borderRadius: 'var(--r-pill)',
        font: 'var(--fw-semibold) var(--fs-micro)/1 var(--font-ui)',
        letterSpacing: '0.03em',
        whiteSpace: 'nowrap',
        ...variants[variant],
        ...style,
      }}
      {...rest}
    >
      {dot && <span style={{ width: 6, height: 6, borderRadius: '50%', background: variant === 'solid' && tone !== 'neutral' ? 'currentColor' : t.dot, flex: '0 0 auto' }} />}
      {children}
    </span>
  );
}
