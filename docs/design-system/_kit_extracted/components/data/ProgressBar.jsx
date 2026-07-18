import React from 'react';

/**
 * Grit — ProgressBar
 * Track + accent-gradient fill. `indeterminate` runs a sweeping shimmer.
 */
export function ProgressBar({
  value = 0,            // 0..100 (ignored if indeterminate)
  indeterminate = false,
  height = 6,
  tone = 'accent',      // 'accent' | 'success' | 'warning' | 'error'
  style,
  ...rest
}) {
  const fills = {
    accent: 'var(--accent-grad)',
    success: 'var(--grit-success)',
    warning: 'var(--grit-warning)',
    error: 'var(--grit-error)',
  };
  const pct = Math.max(0, Math.min(100, value));
  const kf = 'nxProgIndet';

  return (
    <div
      role="progressbar"
      aria-valuenow={indeterminate ? undefined : pct}
      style={{
        position: 'relative',
        width: '100%',
        height,
        borderRadius: 'var(--r-pill)',
        background: 'var(--surface-input)',
        boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.35)',
        overflow: 'hidden',
        ...style,
      }}
      {...rest}
    >
      <style>{`@keyframes ${kf}{0%{left:-40%}100%{left:100%}}`}</style>
      <div
        style={indeterminate ? {
          position: 'absolute',
          top: 0,
          bottom: 0,
          width: '40%',
          borderRadius: 'var(--r-pill)',
          background: fills[tone],
          animation: `${kf} 1.1s var(--ease-in-out) infinite`,
        } : {
          height: '100%',
          width: `${pct}%`,
          borderRadius: 'var(--r-pill)',
          background: fills[tone],
          boxShadow: tone === 'accent' ? 'var(--glow-soft)' : 'none',
          transition: 'width var(--dur-3) var(--ease-out)',
        }}
      />
    </div>
  );
}
