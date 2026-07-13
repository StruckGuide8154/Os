import React from 'react';

/**
 * Grit — Avatar
 * Circular identity token. Falls back to monogram initials on the
 * accent gradient when no image is supplied. Optional status ring.
 */
export function Avatar({
  src,
  name = '',
  size = 36,
  status = null,        // null | 'online' | 'away' | 'busy' | 'offline'
  style,
  ...rest
}) {
  const initials = name
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0].toUpperCase())
    .join('');

  const statusColors = {
    online: 'var(--grit-success)',
    away: 'var(--grit-warning)',
    busy: 'var(--grit-error)',
    offline: 'var(--text-faint)',
  };

  return (
    <span style={{ position: 'relative', display: 'inline-flex', width: size, height: size, flex: '0 0 auto', ...style }} {...rest}>
      <span
        style={{
          width: size,
          height: size,
          borderRadius: '50%',
          overflow: 'hidden',
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: src ? 'var(--surface-input)' : 'var(--accent-grad)',
          color: 'var(--text-invert)',
          font: `var(--fw-semibold) ${Math.round(size * 0.4)}px/1 var(--font-ui)`,
          boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.08)',
        }}
      >
        {src ? <img src={src} alt={name} style={{ width: '100%', height: '100%', objectFit: 'cover' }} /> : initials}
      </span>
      {status && (
        <span
          style={{
            position: 'absolute',
            right: -1,
            bottom: -1,
            width: Math.max(8, size * 0.28),
            height: Math.max(8, size * 0.28),
            borderRadius: '50%',
            background: statusColors[status],
            border: '2px solid var(--surface-window)',
          }}
        />
      )}
    </span>
  );
}
