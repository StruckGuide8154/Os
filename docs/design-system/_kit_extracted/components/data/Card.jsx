import React from 'react';

/**
 * Grit — Card
 * Base surface container. `interactive` adds hover lift; `glow` adds
 * the neon edge for featured/selected cards.
 */
export function Card({
  children,
  padding = 'md',       // 'none' | 'sm' | 'md' | 'lg'
  interactive = false,
  glow = false,
  onClick,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const pads = { none: 0, sm: 12, md: 16, lg: 24 };

  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background: 'var(--surface-panel)',
        border: '1px solid',
        borderColor: glow ? 'var(--focus-ring)' : 'var(--border)',
        borderRadius: 'var(--r-lg)',
        padding: pads[padding],
        boxShadow: glow
          ? 'var(--glow-soft), var(--shadow-md), var(--edge-light)'
          : (interactive && hover ? 'var(--shadow-lg), var(--edge-light)' : 'var(--shadow-sm), var(--edge-light)'),
        transform: interactive && hover ? 'translateY(-2px)' : 'none',
        transition: 'transform var(--dur-2) var(--ease-out), box-shadow var(--dur-2) var(--ease-out), border-color var(--dur-2) var(--ease-out)',
        cursor: interactive ? 'pointer' : 'default',
        ...style,
      }}
      {...rest}
    >
      {children}
    </div>
  );
}
