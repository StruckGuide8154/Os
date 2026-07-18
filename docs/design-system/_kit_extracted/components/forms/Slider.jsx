import React from 'react';

/**
 * Grit — Slider
 * Horizontal range. Filled portion uses the accent gradient; the knob
 * lifts on hover/drag with a soft glow.
 */
export function Slider({
  value = 50,
  min = 0,
  max = 100,
  step = 1,
  disabled = false,
  onChange,
  style,
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const pct = Math.max(0, Math.min(100, ((value - min) / (max - min)) * 100));

  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{ position: 'relative', height: 22, display: 'flex', alignItems: 'center', width: '100%', opacity: disabled ? 0.5 : 1, ...style }}
    >
      {/* track */}
      <div style={{ position: 'absolute', left: 0, right: 0, height: 6, borderRadius: 'var(--r-pill)', background: 'var(--surface-input)', boxShadow: 'inset 0 1px 2px rgba(0,0,0,0.35)' }} />
      {/* fill */}
      <div style={{ position: 'absolute', left: 0, width: `${pct}%`, height: 6, borderRadius: 'var(--r-pill)', background: 'var(--accent-grad)', boxShadow: hover ? 'var(--glow-soft)' : 'none', transition: 'box-shadow var(--dur-2) var(--ease-out)' }} />
      {/* knob */}
      <div
        style={{
          position: 'absolute',
          left: `calc(${pct}% - 9px)`,
          width: 18,
          height: 18,
          borderRadius: '50%',
          background: '#fff',
          border: '2px solid var(--accent)',
          boxShadow: hover ? 'var(--glow-accent)' : '0 1px 4px rgba(0,0,0,0.5)',
          transition: 'box-shadow var(--dur-2) var(--ease-out), transform var(--dur-1) var(--ease-out)',
          transform: hover ? 'scale(1.08)' : 'none',
        }}
      />
      <input
        type="range"
        value={value}
        min={min}
        max={max}
        step={step}
        disabled={disabled}
        onChange={(e) => onChange && onChange(Number(e.target.value))}
        style={{ position: 'absolute', left: 0, right: 0, width: '100%', height: 22, margin: 0, opacity: 0, cursor: disabled ? 'not-allowed' : 'pointer' }}
        {...rest}
      />
    </div>
  );
}
